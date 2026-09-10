import Foundation

/// Reads and writes the video record.
///
/// **Structurally identical to `WatchStore` and `QueueStore`, deliberately**:
/// same envelope, same version probe read separately from the body, same
/// atomic replace, same set-aside recovery. A fourth idiom for "read a JSON
/// file that might be from the future" is a fourth thing to get wrong.
///
/// **Its own file rather than a section of `watches.json`.** That file is
/// small, hot and contended by three writers, and the ordering discipline
/// between them has already produced eight bugs of one shape. This one is
/// append-mostly (`docs/design/video-record.md` §3).
///
/// Dates are ISO-8601 in both directions rather than the encoder default. This
/// file is meant to be readable by a person debugging it, and a reference-date
/// double is not.
public struct VideoRecordStore: Sendable {
  private struct Envelope: Codable {
    static let currentVersion = 1
    var version: Int
    var library: VideoLibrary
  }

  /// Just enough of the envelope to read the schema version, for the reason
  /// `WatchStore.VersionProbe` gives: a future file that changes the library's
  /// shape must read as "wrong version" rather than as a decode failure.
  private struct VersionProbe: Decodable {
    var version: Int
  }

  public let fileURL: URL

  public init(fileURL: URL) {
    self.fileURL = fileURL
  }

  private static var decoder: JSONDecoder {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return decoder
  }

  public func load() throws -> VideoLibrary {
    guard FileManager.default.fileExists(atPath: fileURL.path) else { return VideoLibrary() }
    let data = try Data(contentsOf: fileURL)
    do {
      let probe = try JSONDecoder().decode(VersionProbe.self, from: data)
      guard probe.version == Envelope.currentVersion else { return setAside() }
      return try Self.decoder.decode(Envelope.self, from: data).library
    } catch {
      return setAside()
    }
  }

  /// Moves an unreadable file aside and starts empty. Non-throwing by design:
  /// this is the recovery path, so it must not be able to fail launch itself.
  private func setAside() -> VideoLibrary {
    let backup = fileURL.appendingPathExtension("bak")
    try? FileManager.default.removeItem(at: backup)
    do {
      try FileManager.default.moveItem(at: fileURL, to: backup)
    } catch {
      try? FileManager.default.removeItem(at: fileURL)
    }
    return VideoLibrary()
  }

  public func save(_ library: VideoLibrary) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    let data = try encoder.encode(
      Envelope(version: Envelope.currentVersion, library: library))

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
      // Never leave the scratch file behind: this is the app's persistent data
      // directory, not a temp dir, so a leak accumulates forever.
      try? FileManager.default.removeItem(at: scratch)
      throw error
    }
  }
}
