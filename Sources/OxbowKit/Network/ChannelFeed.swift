import Foundation

/// What can go wrong asking Twitch for a channel's archives.
public enum ChannelFeedError: Error, Equatable, Sendable {
  /// `data.user` was null. Twitch answers 200 with a null user for a login
  /// that does not exist, so this is a normal answer rather than a failure —
  /// but it is not an empty list, and must not be shown as one.
  case noSuchChannel
  /// The anti-automation challenge. Only reachable if a query ever carries
  /// `after:`, which none of ours does; kept distinct so that if it ever
  /// fires it is diagnosable rather than arriving as a parse failure.
  case integrityChallenge
  case server(status: Int)
  /// The response held no video list we could read. Carries a bounded
  /// snippet for the same reason `VideoInfoFetchError` does: the payload's
  /// shape is not a stable contract, and a bare case name gives whoever
  /// debugs a format drift nothing to go on.
  case malformedPayload(snippet: String)
}

extension ChannelFeedError: LocalizedError {
  public var errorDescription: String? {
    switch self {
    case .noSuchChannel: "Twitch has no channel with that name."
    case .integrityChallenge: "Twitch declined the request."
    case .server(let status): "Twitch answered with status \(status)."
    case .malformedPayload: "Twitch's answer could not be read."
    }
  }
}

/// Lists a channel's archived broadcasts.
///
/// **One page, never paginated.** `docs/twitch-channel-api.md` §4 measured
/// `after:` failing an anti-automation integrity challenge, which this
/// project does not attempt to defeat. §5 measured that it does not need to:
/// `first:` caps at 100 and one page reaches back months on every channel
/// sampled.
///
/// The transport is injected rather than reached for, exactly as
/// `UpdateCheck` does it, so every test runs against a stub and the suite
/// never touches the network.
public struct ChannelFeed: Sendable {

  public typealias Fetch = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)

  /// Twitch's own public web client identifier, embedded in twitch.tv's
  /// JavaScript and used by every tool in this space including the CLI this
  /// app bundles. **Not a credential and not ours** — it authenticates
  /// nothing and identifies no user.
  public static let publicClientID = "kimne78kx3ncx6brgo4mv6wki5h1ko"

  public static let defaultEndpoint = URL(string: "https://gql.twitch.tv/gql")!

  /// How much of an unreadable payload `.malformedPayload` keeps, in
  /// `Character`s. Bounded so a runaway response cannot balloon an error
  /// string. Not private: the test pins it.
  static let snippetLimit = 280

  /// The largest page the server will serve, stated by the server itself:
  /// "argument 'first' value must be between 1 and 100."
  public static let maximumLimit = 100

  private let fetch: Fetch
  private let endpoint: URL

  public init(fetch: @escaping Fetch, endpoint: URL = ChannelFeed.defaultEndpoint) {
    self.fetch = fetch
    self.endpoint = endpoint
  }

  public func archives(forLogin login: String, limit: Int = maximumLimit)
    async throws -> [ChannelArchive]
  {
    let (data, response) = try await fetch(request(login: login, limit: limit))
    guard response.statusCode == 200 else {
      throw ChannelFeedError.server(status: response.statusCode)
    }
    return try Self.decode(data)
  }

  private func request(login: String, limit: Int) -> URLRequest {
    var request = URLRequest(url: endpoint)
    request.httpMethod = "POST"
    request.setValue(Self.publicClientID, forHTTPHeaderField: "Client-ID")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try? JSONEncoder().encode(
      ["query": Self.query(login: login, limit: limit)])
    return request
  }

  /// **`previewThumbnailURL` takes arguments and must be given them.** Asked
  /// for bare it returns a URL containing a literal `{width}x{height}`, which
  /// `StreamThumbnail.rewritten(_:)` cannot match — so a bare request would
  /// flow an unusable URL straight through into a 404
  /// (`docs/twitch-channel-api.md` §8). 320x180 matches what the intake
  /// already fetches and rewrites.
  ///
  /// `login` is interpolated into the query, and is constrained to Twitch's
  /// own login alphabet by `Watch.normalisedLogin(_:)` before reaching here.
  /// Nothing else may call this with unsanitised text.
  static func query(login: String, limit: Int) -> String {
    let bounded = min(max(limit, 1), maximumLimit)
    return """
      query { user(login: "\(login)") { id login videos(first: \(bounded), type: ARCHIVE) { \
      edges { node { id title lengthSeconds publishedAt status \
      previewThumbnailURL(width: 320, height: 180) } } } } }
      """
  }

  private static func decode(_ data: Data) throws -> [ChannelArchive] {
    guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      throw ChannelFeedError.malformedPayload(snippet: snippet(data))
    }

    if let errors = root["errors"] as? [[String: Any]],
       errors.contains(where: {
         ($0["extensions"] as? [String: Any])?["code"] as? String == "IntegrityCheckFailed"
       })
    {
      throw ChannelFeedError.integrityChallenge
    }

    guard let payload = root["data"] as? [String: Any] else {
      throw ChannelFeedError.malformedPayload(snippet: snippet(data))
    }
    // Distinguished from "absent": Twitch answers 200 with an explicit null
    // user for an unknown login.
    if payload["user"] is NSNull { throw ChannelFeedError.noSuchChannel }
    guard
      let user = payload["user"] as? [String: Any],
      let videos = user["videos"] as? [String: Any],
      let edges = videos["edges"] as? [[String: Any]]
    else { throw ChannelFeedError.malformedPayload(snippet: snippet(data)) }

    let formatter = ISO8601DateFormatter()
    return edges.compactMap { edge -> ChannelArchive? in
      guard
        let node = edge["node"] as? [String: Any],
        let id = node["id"] as? String,
        let title = node["title"] as? String,
        let seconds = node["lengthSeconds"] as? Int,
        let published = node["publishedAt"] as? String,
        let date = formatter.date(from: published)
      else { return nil }

      return ChannelArchive(
        id: id,
        title: title,
        duration: .seconds(seconds),
        publishedAt: date,
        status: .init(rawValue: node["status"] as? String ?? ""),
        thumbnailURL: (node["previewThumbnailURL"] as? String).flatMap(URL.init(string:)))
    }
  }

  private static func snippet(_ data: Data) -> String {
    String(String(decoding: data, as: UTF8.self).prefix(snippetLimit))
  }
}
