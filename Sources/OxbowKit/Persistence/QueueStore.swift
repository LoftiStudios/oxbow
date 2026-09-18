import Foundation

/// Atomic queue persistence via a temporary file and `replaceItemAt` to avoid crash-truncated
/// state.
public struct QueueStore: Sendable {
  private struct Envelope: Codable {
    static let currentVersion = 1
    var version: Int
    var jobs: [Job]
  }

  /// Read the version before decoding jobs, whose schema may have changed in a future file.
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

    // Recover every decode failure so a corrupt queue cannot block all subsequent launches.
    do {
      let probe = try JSONDecoder().decode(VersionProbe.self, from: data)
      guard probe.version == Envelope.currentVersion else { return setAside() }
      return try JSONDecoder().decode(Envelope.self, from: data).jobs
    } catch {
      return setAside()
    }
  }

  /// Sets an unreadable queue aside as `queue.json.bak` and starts empty. If moving fails,
  /// attempts removal to avoid repeating the failure. Recovery must not throw and block launch.
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
      // Always remove scratch files from persistent storage.
      try? FileManager.default.removeItem(at: scratch)
      throw error
    }
  }
}
