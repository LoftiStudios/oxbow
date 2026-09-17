import Foundation

/// Atomic, versioned video-record persistence with set-aside recovery, matching the other
/// stores. Separate from the frequently updated watch list. Dates use readable ISO-8601.
public struct VideoRecordStore: Sendable {
  private struct Envelope: Codable {
    static let currentVersion = 1
    var version: Int
    var library: VideoLibrary
  }

  /// Read the version without requiring a future library schema to decode.
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
      // Always remove scratch files from persistent storage.
      try? FileManager.default.removeItem(at: scratch)
      throw error
    }
  }
}
