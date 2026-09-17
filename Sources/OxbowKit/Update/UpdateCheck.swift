import Foundation

/// A check that failed in a way worth telling the user about, as distinct from
/// a check that succeeded and found nothing.
public enum UpdateCheckError: Error, Equatable, Sendable {
  /// Unexpected HTTP response from the releases API.
  case server(status: Int)
}

extension UpdateCheckError: LocalizedError {
  /// Readable errors for manual checks, including a specific rate-limit message.
  public var errorDescription: String? {
    switch self {
    case .server(let status) where status == 403:
      return "GitHub's rate limit was reached. Try again in an hour."
    case .server(let status):
      return "GitHub answered with status \(status)."
    }
  }
}

/// Compares the latest published release with the running version. Injected request transport
/// keeps tests offline and exposes headers for assertions.
public struct UpdateCheck: Sendable {

  public enum Outcome: Equatable, Sendable {
    case upToDate
    case available(ReleaseVersion, URL)
  }

  public typealias Fetch = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)

  /// GitHub's latest-release endpoint excludes drafts and prereleases, so users see releases
  /// only after publication.
  public static let defaultEndpoint = URL(
    string: "https://api.github.com/repos/LoftiStudios/oxbow/releases/latest")!

  private let currentVersion: String
  private let endpoint: URL
  private let fetch: Fetch

  public init(
    currentVersion: String,
    endpoint: URL = UpdateCheck.defaultEndpoint,
    fetch: @escaping Fetch)
  {
    self.currentVersion = currentVersion
    self.endpoint = endpoint
    self.fetch = fetch
  }

  public func run() async throws -> Outcome {
    var request = URLRequest(url: endpoint)
    request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
    // api.github.com answers 403 to a request with no User-Agent.
    request.setValue("Oxbow/\(currentVersion)", forHTTPHeaderField: "User-Agent")

    let (data, response) = try await fetch(request)
    guard (200..<300).contains(response.statusCode) else {
      throw UpdateCheckError.server(status: response.statusCode)
    }

    let release = try JSONDecoder().decode(LatestRelease.self, from: data)

    // Only offer newer versions; latest may move backwards after a release is unpublished.
    guard let current = ReleaseVersion(currentVersion),
          let latest = ReleaseVersion(release.tagName),
          latest > current
    else { return .upToDate }

    return .available(latest, release.htmlURL)
  }

  /// Explicit keys preserve `htmlURL` capitalization; snake-case conversion would produce
  /// `htmlUrl`.
  private struct LatestRelease: Decodable {
    let tagName: String
    let htmlURL: URL

    enum CodingKeys: String, CodingKey {
      case tagName = "tag_name"
      case htmlURL = "html_url"
    }
  }
}
