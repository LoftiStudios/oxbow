import CryptoKit
import Foundation

/// Durable image storage for history after Twitch URLs expire. Never evicts automatically; the
/// history owner supplies the keep-set to `purge(keeping:)`. Actor isolation keeps file/network
/// work off the main actor. Failures return nil for placeholder display.
public actor ImageStore {

  private let directory: URL
  private let fetch: @Sendable (URL) async throws -> Data

  public init(directory: URL, fetch: @escaping @Sendable (URL) async throws -> Data) {
    self.directory = directory
    self.fetch = fetch
  }

  /// Uses an ephemeral session to avoid duplicating this store in URLCache.
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

    // Cache only successful bytes; an empty failure file would become a permanent hit.
    try? FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: true)
    try? fetched.write(to: file, options: .atomic)
    return fetched
  }

  /// Deletes images outside the owner's keep-set. Hash URLs forward to compare stored
  /// filenames; deletion failures are nonfatal.
  public func purge(keeping: Set<URL>) {
    let survivors = Set(keeping.map(Self.filename(for:)))
    guard let stored = try? FileManager.default.contentsOfDirectory(
      atPath: directory.path) else { return }

    for name in stored where !survivors.contains(name) {
      try? FileManager.default.removeItem(at: directory.appending(path: name))
    }
  }

  /// Hashes the whole URL: Twitch thumbnails share filenames across different paths. Preserves
  /// an allowed extension for inspection.
  nonisolated static func filename(for url: URL) -> String {
    let digest = SHA256.hash(data: Data(url.absoluteString.utf8))
    let hash = digest.map { String(format: "%02x", $0) }.joined()
    return "\(hash).\(fileExtension(of: url))"
  }

  /// Allowed filename extensions; unknown network-supplied values use the default.
  private static let namedExtensions: Set<String> = ["jpg", "jpeg", "png", "gif", "webp"]

  /// Preserves the URL's image extension for Finder/Quick Look. Twitch serves JPEG and PNG; a
  /// fixed `.jpg` would mislabel files. Query parameters are excluded.
  nonisolated static func fileExtension(of url: URL) -> String {
    let candidate = url.pathExtension.lowercased()
    return namedExtensions.contains(candidate) ? candidate : "jpg"
  }
}
