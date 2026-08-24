import Foundation

/// Reads and writes the queue file.
///
/// Writes go through a temporary file and `replaceItemAt`, because a truncated
/// queue.json from a crash mid-write would lose the entire queue — a trivially
/// avoidable class of bug.
public struct QueueStore: Sendable {
  private struct Envelope: Codable {
    static let currentVersion = 1
    var version: Int
    var jobs: [Job]
  }

  /// Just enough of the envelope to read the schema version.
  ///
  /// Decoding the full `Envelope` first would defeat the version field
  /// entirely: `jobs: [Job]` has to decode before the version check can run,
  /// so a v2 file that changes `Job`'s shape — precisely what the version
  /// exists to signal — would throw before anything looked at the number.
  private struct VersionProbe: Decodable {
    var version: Int
  }

  public let fileURL: URL

  public init(fileURL: URL) {
    self.fileURL = fileURL
  }

  public func load() throws -> [Job] {
    guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }

    let data = try Data(contentsOf: fileURL)

    // Every decode failure is recovered the same way, not just a version
    // mismatch. A file we cannot read is a file the user cannot fix: without
    // this, a single corrupt byte means `start()` throws, the app never
    // launches, the bad file is never set aside, and it fails identically on
    // every subsequent launch forever.
    do {
      let probe = try JSONDecoder().decode(VersionProbe.self, from: data)
      guard probe.version == Envelope.currentVersion else { return setAside() }
      return try JSONDecoder().decode(Envelope.self, from: data).jobs
    } catch {
      return setAside()
    }
  }

  /// Moves an unreadable queue file aside as `queue.json.bak` and starts
  /// empty. Best-effort by design and deliberately non-throwing: this is the
  /// recovery path, so it must not be able to fail launch itself. If the move
  /// cannot be done, the file is removed instead — leaving it in place would
  /// reproduce the same failure on the next launch.
  private func setAside() -> [Job] {
    let backup = fileURL.appendingPathExtension("bak")
    try? FileManager.default.removeItem(at: backup)
    do {
      try FileManager.default.moveItem(at: fileURL, to: backup)
    } catch {
      try? FileManager.default.removeItem(at: fileURL)
    }
    return []
  }

  public func save(_ jobs: [Job]) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(Envelope(version: Envelope.currentVersion, jobs: jobs))

    try FileManager.default.createDirectory(
      at: fileURL.deletingLastPathComponent(),
      withIntermediateDirectories: true)

    let scratch = fileURL.deletingLastPathComponent()
      .appending(path: ".\(fileURL.lastPathComponent).\(UUID().uuidString)")

    do {
      try data.write(to: scratch)

      if FileManager.default.fileExists(atPath: fileURL.path) {
        _ = try FileManager.default.replaceItemAt(fileURL, withItemAt: scratch)
      } else {
        try FileManager.default.moveItem(at: scratch, to: fileURL)
      }
    } catch {
      // Never leave the scratch file behind: this directory is the app's
      // persistent data directory, not a throwaway temp dir, so a leak here
      // accumulates hidden files forever rather than being swept on reboot.
      try? FileManager.default.removeItem(at: scratch)
      throw error
    }
  }
}
