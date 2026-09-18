import Foundation

/// Stores raw CLI info beside the video record so future parsers can recover fields not
/// currently used without enlarging `videos.json`. The corresponding `VideoRecord` stamps the
/// helper version because the raw format is unstable.
public struct PayloadStore: Sendable {

  public enum Failure: Error, Equatable {
    /// The id could not be used as a filename. Refused rather than sanitised:
    /// mapping two different ids onto one filename would silently return the
    /// wrong video's payload.
    case unusableIdentifier
  }

  public let directory: URL

  public init(directory: URL) {
    self.directory = directory
  }

  /// Allow only Twitch ID/clip-slug characters (`A-Za-z0-9_-`) in filenames.
  private static func filename(for id: String) -> String? {
    guard !id.isEmpty, id.count <= 128 else { return nil }
    let allowed = CharacterSet(charactersIn:
      "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-")
    guard id.unicodeScalars.allSatisfy(allowed.contains) else { return nil }
    return "\(id).txt"
  }

  public func save(_ payload: String, for id: String) throws {
    guard let filename = Self.filename(for: id) else { throw Failure.unusableIdentifier }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try Data(payload.utf8).write(to: directory.appending(path: filename), options: .atomic)
  }

  /// Returns nil for missing or unreadable optional payloads.
  public func payload(for id: String) -> String? {
    guard let filename = Self.filename(for: id) else { return nil }
    guard let data = try? Data(contentsOf: directory.appending(path: filename)) else { return nil }
    return String(decoding: data, as: UTF8.self)
  }

  public func remove(ids: Set<String>) {
    for id in ids {
      guard let filename = Self.filename(for: id) else { continue }
      try? FileManager.default.removeItem(at: directory.appending(path: filename))
    }
  }
}
