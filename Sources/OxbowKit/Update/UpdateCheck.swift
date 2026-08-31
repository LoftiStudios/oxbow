import Foundation

/// A check that failed in a way worth telling the user about, as distinct from
/// a check that succeeded and found nothing.
public enum UpdateCheckError: Error, Equatable, Sendable {
  /// The API answered, but not with a release. 403 is the rate limit (60/hour
  /// per IP, unauthenticated); 404 is a repository that moved further than
  /// GitHub's rename redirect follows.
  case server(status: Int)
}

extension UpdateCheckError: LocalizedError {
  /// Without this, `localizedDescription` is the stock
  /// "The operation couldn't be completed. (OxbowKit.UpdateCheckError error 0.)",
  /// which is what a user who pressed Check for Updates would otherwise be
  /// told. 403 is called out by name because it is the one users will actually
  /// hit and the one that resolves itself by waiting.
  public var errorDescription: String? {
    switch self {
    case .server(let status) where status == 403:
      return "GitHub's rate limit was reached. Try again in an hour."
    case .server(let status):
      return "GitHub answered with status \(status)."
    }
  }
}

/// Asks GitHub what the newest published release is, and compares it to the
/// version that is running.
///
/// The transport is injected rather than reached for, so every test here runs
/// against a stub and the suite never touches the network. `URLRequest` rather
/// than `URL` is the closure's argument specifically so the headers are part
/// of what can be asserted — see `identifiesItselfWithAUserAgent`.
public struct UpdateCheck: Sendable {

  public enum Outcome: Equatable, Sendable {
    case upToDate
    case available(ReleaseVersion, URL)
  }

  public typealias Fetch = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)

  /// `/releases/latest`, which excludes drafts and prereleases on GitHub's
  /// side. That pairs exactly with `release.yml` creating every release as a
  /// draft: a release is invisible here until a human publishes it, which is
  /// the moment existing installs are meant to start seeing it.
  ///
  /// Force-unwrapped because it is a literal with no input to be malformed by,
  /// and `asksForTheLatestReleaseOfTheConfiguredRepository` fails loudly if it
  /// is ever edited into something that will not parse.
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

    // Strictly greater. Equal is current, and *older* is a real state — an
    // unpublished release moves `/releases/latest` backwards — which must not
    // become an invitation to downgrade.
    guard let current = ReleaseVersion(currentVersion),
          let latest = ReleaseVersion(release.tagName),
          latest > current
    else { return .upToDate }

    return .available(latest, release.htmlURL)
  }

  /// The two fields we read, out of the several dozen the endpoint returns.
  ///
  /// Explicit keys rather than `.convertFromSnakeCase`, which would map
  /// `html_url` to `htmlUrl` and not to the correctly-capitalised `htmlURL`.
  private struct LatestRelease: Decodable {
    let tagName: String
    let htmlURL: URL

    enum CodingKeys: String, CodingKey {
      case tagName = "tag_name"
      case htmlURL = "html_url"
    }
  }
}
