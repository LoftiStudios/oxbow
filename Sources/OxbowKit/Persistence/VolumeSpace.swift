import Foundation

/// Reads how much room a volume has, and decides whether a job fits on it.
///
/// A struct of closures rather than direct `URLResourceValues` calls at each
/// call site, so both consumers are testable without a real disk. Filling a
/// volume to test a warning is not a test anybody runs twice, which in practice
/// means it is not a test that gets run.
///
/// The arithmetic lives here and the estimate lives in `SpaceEstimate`, because
/// the estimate is pure and this is not: keeping the I/O on one side of that
/// line is what lets the intake recompute an estimate on every keystroke and
/// touch the disk only when it has a reason to.
public struct VolumeSpace: Sendable {

  /// A volume that does not have room, and by how much.
  public struct Shortfall: Sendable, Equatable {
    public var needed: Int64
    public var available: Int64
    /// The name a person would recognise — what Finder calls it.
    public var volumeName: String

    public init(needed: Int64, available: Int64, volumeName: String) {
      self.needed = needed
      self.available = available
      self.volumeName = volumeName
    }
  }

  public var availableBytes: @Sendable (URL) -> Int64?
  /// The mount point a path sits on, for telling one volume from two.
  public var volumeRoot: @Sendable (URL) -> URL?
  public var volumeName: @Sendable (URL) -> String?

  public init(
    availableBytes: @escaping @Sendable (URL) -> Int64?,
    volumeRoot: @escaping @Sendable (URL) -> URL?,
    volumeName: @escaping @Sendable (URL) -> String?)
  {
    self.availableBytes = availableBytes
    self.volumeRoot = volumeRoot
    self.volumeName = volumeName
  }

  /// The volume this job does not fit on, or `nil` if it fits.
  ///
  /// - Parameters:
  ///   - needingWorkspace: `SpaceEstimate.total`. Everything coexists in the
  ///     workspace while the composite is being written.
  ///   - delivered: `SpaceEstimate.delivered`. The one file that lands at the
  ///     destination.
  ///
  /// **One volume is checked against `needingWorkspace` alone, not against
  /// `needingWorkspace + delivered`.** `SpaceEstimate.total` already contains
  /// the composite that gets delivered, and a same-volume `moveItem` is a
  /// rename rather than a copy, so delivery costs nothing on top. Adding it
  /// again would make every same-volume warning fire about a composite's worth
  /// of bytes too early.
  ///
  /// Across volumes the two needs are independent and each side is checked
  /// against its own: summing them would produce a number describing neither.
  ///
  /// **A failed read is not a shortfall.** Any of these values being
  /// unavailable returns `nil` rather than a guess. A warning invented from a
  /// failed probe is one the user cannot act on, and it would fire on exactly
  /// the unusual arrangements — network shares, odd mounts — where it is least
  /// likely to be right.
  public func shortfall(
    needingWorkspace: Int64,
    delivered: Int64,
    workspace: URL,
    destination: URL) -> Shortfall?
  {
    guard let workspaceRoot = volumeRoot(workspace),
          let destinationRoot = volumeRoot(destination)
    else { return nil }

    guard workspaceRoot != destinationRoot else {
      return check(needingWorkspace, at: workspace)
    }

    // Workspace first only for determinism when both are short. Which one is
    // named barely matters — the user has to clear one of them either way —
    // but naming a different volume on each evaluation would read as a bug.
    return check(needingWorkspace, at: workspace) ?? check(delivered, at: destination)
  }

  private func check(_ needed: Int64, at path: URL) -> Shortfall? {
    guard let available = availableBytes(path), available < needed else { return nil }
    return Shortfall(
      needed: needed,
      available: available,
      volumeName: volumeName(path) ?? path.lastPathComponent)
  }

  /// Picks between the two capacity keys.
  ///
  /// **`volumeAvailableCapacityForImportantUsage` is preferred but cannot be
  /// trusted alone, because on a network volume it answers zero.** Measured
  /// on an SMB share with 8 TB free: `importantUsage` returned 0 bytes while
  /// `volumeAvailableCapacity` returned 8035.90 GB. Not nil — zero — so
  /// every `??` fallback in the codebase sailed straight past it and a NAS
  /// destination read as a completely full disk. `AutoDownloadPolicy` then
  /// demoted that channel on every sweep, permanently, and said "Only Zero
  /// KB free" while doing it.
  ///
  /// Taking the larger of the two gets both cases right without having to
  /// ask what kind of volume this is. On a local disk `importantUsage` is
  /// the larger — it counts space the system will purge to satisfy an
  /// important write, which is what actually happens when a download needs
  /// room, and on a Mac carrying a large snapshot store the two differ by
  /// tens of gigabytes. On a network volume the plain figure is the larger
  /// by everything the share has.
  ///
  /// Returns nil only when neither key answers, which stays distinct from
  /// "answered, and the number is zero" — a distinction this function exists
  /// because something else lost.
  ///
  /// **`importantUsage` is optimistic about a local disk, and this keeps
  /// that.** It counts purgeable space, so it reads higher than Finder does
  /// — 125.40 GB against 57.33 GB on the machine measured above. That was
  /// already the documented choice for the intake's warning and is not being
  /// changed here, but it does mean a reserve set against this number is
  /// protecting less than its label suggests.
  static func betterCapacity(important: Int64?, plain: Int64?) -> Int64? {
    switch (important, plain) {
    case (nil, nil): return nil
    case (let a?, nil): return a
    case (nil, let b?): return b
    case (let a?, let b?): return max(a, b)
    }
  }

  /// The real probe.
  public static let live = VolumeSpace(
    availableBytes: { url in
      guard let existing = nearestExisting(url) else { return nil }
      let values = try? existing.resourceValues(forKeys: [
        .volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey])
      return betterCapacity(
        important: values?.volumeAvailableCapacityForImportantUsage,
        plain: values?.volumeAvailableCapacity.map(Int64.init))
    },
    volumeRoot: { url in
      guard let existing = nearestExisting(url) else { return nil }
      return (try? existing.resourceValues(forKeys: [.volumeURLKey]))?.volume
    },
    volumeName: { url in
      guard let existing = nearestExisting(url) else { return nil }
      return (try? existing.resourceValues(forKeys: [.volumeNameKey]))?.volumeName
    })

  /// The nearest ancestor of `url` that exists, or `nil` if even the root does
  /// not resolve.
  ///
  /// The workspace directory does not exist on a first launch, and the intake
  /// asks about it anyway. `resourceValues` on a missing path throws rather
  /// than answering about the volume the path *would* live on, so every live
  /// read walks up until it finds something real — the answer is a property of
  /// the volume, and every ancestor shares it.
  private static func nearestExisting(_ url: URL) -> URL? {
    var candidate = url.standardizedFileURL
    while !FileManager.default.fileExists(atPath: candidate.path) {
      let parent = candidate.deletingLastPathComponent()
      guard parent != candidate else { return nil }
      candidate = parent
    }
    return candidate
  }
}
