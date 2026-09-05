import Foundation

/// Reads and writes the watch list.
///
/// Structurally identical to `QueueStore`, and deliberately so: same
/// envelope, same version probe, same atomic replace, same set-aside
/// recovery.
public struct WatchStore: Sendable {
  private struct Envelope: Codable {
    static let currentVersion = 1
    var version: Int
    var watches: [Watch]
  }

  /// Just enough of the envelope to read the schema version.
  ///
  /// The version is read on its own so the check does not depend on
  /// `watches` being decodable at all — a v2 file that changes `Watch`'s
  /// shape, precisely what the version field exists to signal, is read as
  /// "wrong version" rather than as whatever `Envelope`'s decode failure
  /// would otherwise look like. It does **not** currently change what
  /// happens on that file: with today's catch-all `catch { setAside() }`
  /// below, decoding the full envelope first and probing first both land in
  /// the identical recovery for every input this guards against. The probe
  /// earns its keep the day that recovery is narrowed to something
  /// version-aware — at that point the ordering stops being cosmetic and
  /// starts being the only thing telling "wrong version" apart from
  /// "corrupt".
  private struct VersionProbe: Decodable {
    var version: Int
  }

  public let fileURL: URL

  public init(fileURL: URL) {
    self.fileURL = fileURL
  }

  public func load() throws -> [Watch] {
    guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
    let data = try Data(contentsOf: fileURL)
    do {
      let probe = try JSONDecoder().decode(VersionProbe.self, from: data)
      guard probe.version == Envelope.currentVersion else { return setAside() }
      return try JSONDecoder().decode(Envelope.self, from: data).watches
    } catch {
      return setAside()
    }
  }

  /// Moves an unreadable file aside and starts empty. Non-throwing by
  /// design: this is the recovery path, so it must not be able to fail
  /// launch itself. If the move cannot be done the file is removed instead —
  /// leaving it would reproduce the same failure on every launch.
  private func setAside() -> [Watch] {
    let backup = fileURL.appendingPathExtension("bak")
    try? FileManager.default.removeItem(at: backup)
    do {
      try FileManager.default.moveItem(at: fileURL, to: backup)
    } catch {
      try? FileManager.default.removeItem(at: fileURL)
    }
    return []
  }

  public func save(_ watches: [Watch]) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(
      Envelope(version: Envelope.currentVersion, watches: watches))

    try FileManager.default.createDirectory(
      at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)

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
      // Never leave the scratch file behind: this is the app's persistent
      // data directory, not a temp dir, so a leak accumulates forever.
      try? FileManager.default.removeItem(at: scratch)
      throw error
    }
  }
}
