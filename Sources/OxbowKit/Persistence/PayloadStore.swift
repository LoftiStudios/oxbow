import Foundation

/// Keeps the CLI's raw `info` output so a later parser can read fields today's
/// one ignores.
///
/// **Why verbatim rather than parsed.** `VideoInfo.parse` reads a fraction of
/// what `info --format Raw` emits — the moments line is not parsed at all, the
/// m3u8 only for `RESOLUTION` and `BANDWIDTH`, and the video-info JSON through
/// a five-field envelope. Parsing and discarding freezes today's field set into
/// the archive, so a feature that later wants chapter markers could have them
/// for videos downloaded after it ships and never for anything already kept
/// (`docs/design/video-record.md` §3.3).
///
/// **Beside the JSON, not inside it.** A payload measures about 3.4 KB; keeping
/// them in `videos.json` would make the file the whole app re-reads and
/// rewrites grow linearly with every video ever downloaded.
///
/// The helper version that produced each payload is stamped on the
/// corresponding `VideoRecord`, not here — `--format Raw`'s shape is not a
/// stable upstream contract, so a payload is only re-parseable if a future
/// parser can tell which dialect it is in.
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

  /// Twitch ids are digits and clip slugs are `[A-Za-z0-9_-]`. Anything else
  /// is rejected — this builds a filename from caller-supplied text, and the
  /// only safe posture is the one `Watch.normalisedLogin` already takes.
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

  /// Nil for anything not stored. Non-throwing for the reason `ImageStore`
  /// gives: every byte here is a bonus, and a caller should not have to handle
  /// errors about a field nobody has asked for yet.
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
