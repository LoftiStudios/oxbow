import CryptoKit
import Foundation

/// Keeps fetched images on disk so they outlive the URL they came from.
///
/// **This exists because Twitch's images disappear.** An archive's
/// `previewThumbnailURL` stops resolving when the archive expires, and
/// `docs/design/channel-history.md` keeps a row for that archive
/// indefinitely. Without a durable copy every historical row would be a grey
/// rectangle, and a cold launch with the network down would be a grey page.
///
/// **A store, not a cache, and the distinction is the whole design.** It
/// never evicts. A thumbnail measures about 15 KB and an avatar about
/// 150 KB, and Twitch serves at most 100 archives per channel, so a channel
/// streaming three times a week for five years accumulates roughly 12 MB.
/// Any capacity cap worth setting would never fire — a mechanism guarding an
/// event that does not happen, and therefore never exercised. Images are
/// owned instead: when a channel's history goes away, its images go with it.
/// That deletion is never this type's decision — it only offers `purge(
/// keeping:)`, and whatever owns the history says which images survive.
///
/// `URLCache` was the obvious alternative and is the wrong tool: it honours
/// `Cache-Control` and may be purged by the system whenever it likes, so a
/// feature whose entire requirement is "these bytes outlive their source"
/// cannot be built on it.
///
/// An `actor` rather than a `@MainActor` type: this does file and network
/// I/O, and the pane will ask for a screenful of images at once.
///
/// **Nothing here is authoritative.** Every byte is re-derivable from the
/// network while the source still exists, so every failure path answers nil
/// and lets the caller show a placeholder. A store that threw would make
/// callers handle errors about decoration.
public actor ImageStore {

  private let directory: URL
  private let fetch: @Sendable (URL) async throws -> Data

  public init(directory: URL, fetch: @escaping @Sendable (URL) async throws -> Data) {
    self.directory = directory
    self.fetch = fetch
  }

  /// The real one. Ephemeral session for the same reason `WatchPoller.live`
  /// uses one: this keeps its own durable copy, so letting `URLCache` keep a
  /// second would be duplicated storage answering the same question.
  public static func live(directory: URL) -> ImageStore {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.timeoutIntervalForRequest = 15
    let session = URLSession(configuration: configuration)
    return ImageStore(directory: directory, fetch: { url in
      let (data, response) = try await session.data(from: url)
      guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
        throw URLError(.badServerResponse)
      }
      return data
    })
  }

  /// The bytes for `url`, from disk if they are there and from the network
  /// otherwise. `nil` when it is neither stored nor fetchable.
  public func data(for url: URL) async -> Data? {
    let file = directory.appending(path: Self.filename(for: url))
    if let stored = try? Data(contentsOf: file) { return stored }

    guard let fetched = try? await fetch(url) else { return nil }

    // Written only on success. A zero-byte file left behind by a failure
    // would read as a hit forever after, storing the failure permanently.
    try? FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: true)
    try? fetched.write(to: file, options: .atomic)
    return fetched
  }

  /// Deletes every stored image whose URL is not in `keeping`.
  ///
  /// **The eviction rule this store was written to wait for.** It never evicts
  /// on its own — a thumbnail is about 15 KB against VODs measured in
  /// gigabytes, so any capacity cap worth setting would never fire. Images are
  /// owned instead, and this is how the owner disowns them
  /// (`docs/design/video-record.md` §3.6).
  ///
  /// Keyed by filename rather than by URL, because the filename is all the
  /// directory knows: the SHA-256 is one-way, so the keep-set is hashed
  /// forward and compared, never the stored names reversed.
  ///
  /// Silent on every failure, like the rest of this type. A file that will not
  /// delete costs 15 KB.
  public func purge(keeping: Set<URL>) {
    let survivors = Set(keeping.map(Self.filename(for:)))
    guard let stored = try? FileManager.default.contentsOfDirectory(
      atPath: directory.path) else { return }

    for name in stored where !survivors.contains(name) {
      try? FileManager.default.removeItem(at: directory.appending(path: name))
    }
  }

  /// A filesystem-safe, collision-resistant name for a URL.
  ///
  /// SHA-256 of the whole absolute string, not the last path component:
  /// Twitch's thumbnail URLs differ deep in the path and share their
  /// filename, so naming by `lastPathComponent` would make every archive in
  /// a channel collide onto one image.
  nonisolated static func filename(for url: URL) -> String {
    let digest = SHA256.hash(data: Data(url.absoluteString.utf8))
    return digest.map { String(format: "%02x", $0) }.joined()
  }
}
