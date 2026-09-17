import Foundation

/// Injected volume probes and fit checks. Keep disk I/O separate from `SpaceEstimate`'s pure
/// arithmetic so intake can update estimates without probing on every keystroke.
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

  /// Returns a shortfall, or nil when none is found or a probe fails. `needingWorkspace` is
  /// peak workspace use; `delivered` is final output size. On one volume, check only workspace
  /// need because delivery is a rename. Across volumes, check each need independently.
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

    // Check workspace first for deterministic reporting when both volumes are short.
    return check(needingWorkspace, at: workspace) ?? check(delivered, at: destination)
  }

  private func check(_ needed: Int64, at path: URL) -> Shortfall? {
    guard let available = availableBytes(path), available < needed else { return nil }
    return Shortfall(
      needed: needed,
      available: available,
      volumeName: volumeName(path) ?? path.lastPathComponent)
  }

  /// Use the larger capacity reading: important-usage capacity includes purgeable space locally
  /// but can report zero on SMB despite free space. Nil means neither probe answered. Local
  /// estimates remain optimistic because purgeable bytes are included.
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

  /// Probe the nearest existing ancestor when the target directory does not yet exist, such as
  /// on first launch.
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
