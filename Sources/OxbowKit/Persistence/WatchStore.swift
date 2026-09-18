import Foundation

/// Atomic, versioned watch-list persistence with set-aside recovery, matching `QueueStore`.
public struct WatchStore: Sendable {
  private struct Envelope: Codable {
    static let currentVersion = 1
    var version: Int
    var watches: [Watch]
  }

  /// Read the version before the body so future schema changes can be identified independently
  /// of decoding. Current catch-all recovery treats wrong versions and corruption alike.
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

  /// Sets unreadable state aside and starts empty without blocking launch. Attempts removal if
  /// the backup move fails.
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
      // Always remove scratch files from persistent storage.
      try? FileManager.default.removeItem(at: scratch)
      throw error
    }
  }
}
