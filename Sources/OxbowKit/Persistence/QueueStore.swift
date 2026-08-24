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

  public let fileURL: URL

  public init(fileURL: URL) {
    self.fileURL = fileURL
  }

  public func load() throws -> [Job] {
    guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }

    let data = try Data(contentsOf: fileURL)
    let envelope = try JSONDecoder().decode(Envelope.self, from: data)

    // Do not guess at a schema we do not understand, and do not crash on it.
    guard envelope.version == Envelope.currentVersion else {
      let backup = fileURL.appendingPathExtension("bak")
      try? FileManager.default.removeItem(at: backup)
      try FileManager.default.moveItem(at: fileURL, to: backup)
      return []
    }

    return envelope.jobs
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
    try data.write(to: scratch)

    if FileManager.default.fileExists(atPath: fileURL.path) {
      _ = try FileManager.default.replaceItemAt(fileURL, withItemAt: scratch)
    } else {
      try FileManager.default.moveItem(at: scratch, to: fileURL)
    }
  }
}
