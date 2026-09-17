import Foundation

/// What can go wrong asking Twitch for a channel's archives.
public enum ChannelFeedError: Error, Equatable, Sendable {
  /// Twitch returns HTTP 200 with a null user for an unknown login. Distinct from an empty
  /// archive list.
  case noSuchChannel
  /// Anti-automation challenge, observed with pagination. Kept distinct for diagnosis.
  case integrityChallenge
  case server(status: Int)
  /// Unreadable video list, with a bounded response snippet to diagnose upstream format
  /// changes.
  case malformedPayload(snippet: String)
  /// Transport failure (offline, DNS, TLS), distinct from a server response or malformed
  /// payload.
  case unreachable(String)
}

extension ChannelFeedError: LocalizedError {
  public var errorDescription: String? {
    switch self {
    case .noSuchChannel: "Twitch has no channel with that name."
    case .integrityChallenge: "Twitch declined the request."
    case .server(let status): "Twitch answered with status \(status)."
    case .malformedPayload: "Twitch's answer could not be read."
    case .unreachable(let detail): "Oxbow could not reach Twitch. \(detail)"
    }
  }
}

/// Fetches one page of archives using an injected transport. Pagination triggers an integrity
/// challenge; the 100-item maximum covered months in measured channels. See
/// `docs/twitch-channel-api.md` §§4–5.
public struct ChannelFeed: Sendable {

  public typealias Fetch = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)

  /// Twitch's public web-client identifier, not a user credential.
  public static let publicClientID = "kimne78kx3ncx6brgo4mv6wki5h1ko"

  public static let defaultEndpoint = URL(string: "https://gql.twitch.tv/gql")!

  /// Maximum error-snippet bytes, applied before UTF-8 decoding to bound allocation.
  static let snippetLimit = 280

  /// The largest page the server will serve, stated by the server itself:
  /// "argument 'first' value must be between 1 and 100."
  public static let maximumLimit = 100

  /// Use a served avatar size: 28, 50, 70, 150, 300, or 600. Arbitrary widths produce
  /// valid-looking URLs that 404. See `docs/twitch-channel-api.md` §9.2.
  public static let avatarWidth = 300

  /// Box art resizes on demand, unlike avatars. Supply dimensions explicitly or Twitch returns
  /// literal `{width}x{height}` placeholders.
  public static let categoryArtWidth = 144
  public static let categoryArtHeight = 192

  private let fetch: Fetch
  private let endpoint: URL

  public init(fetch: @escaping Fetch, endpoint: URL = ChannelFeed.defaultEndpoint) {
    self.fetch = fetch
    self.endpoint = endpoint
  }

  /// Validate with `Watch.normalisedLogin(_:)` before calling: login is interpolated unescaped
  /// into GraphQL.
  public func archives(forLogin login: String, limit: Int = maximumLimit)
    async throws -> [ChannelArchive]
  {
    let (data, response) = try await fetch(request(query: Self.query(login: login, limit: limit)))
    guard response.statusCode == 200 else {
      throw ChannelFeedError.server(status: response.statusCode)
    }
    return try Self.decode(data)
  }

  /// Fetches display name and avatar when adding a channel, separately from recurring archive
  /// polls. Validate login with `Watch.normalisedLogin(_:)` before interpolation.
  public func profile(forLogin login: String) async throws -> ChannelProfile {
    let (data, response) = try await fetch(request(query: Self.profileQuery(login: login)))
    guard response.statusCode == 200 else {
      throw ChannelFeedError.server(status: response.statusCode)
    }
    return try Self.decodeProfile(data)
  }

  private func request(query: String) -> URLRequest {
    var request = URLRequest(url: endpoint)
    request.httpMethod = "POST"
    request.setValue(Self.publicClientID, forHTTPHeaderField: "Client-ID")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try? JSONEncoder().encode(["query": query])
    return request
  }

  /// Request explicit thumbnail dimensions; a bare field returns unusable `{width}x{height}`
  /// placeholders. Login must satisfy `archives(forLogin:limit:)`'s validation contract.
  static func query(login: String, limit: Int) -> String {
    let bounded = min(max(limit, 1), maximumLimit)
    return """
      query { user(login: "\(login)") { id login videos(first: \(bounded), type: ARCHIVE) { \
      edges { node { id title lengthSeconds publishedAt status \
      previewThumbnailURL(width: 320, height: 180) \
      game { name boxArtURL(width: \(categoryArtWidth), height: \(categoryArtHeight)) } \
      } } } } }
      """
  }

  /// `login` must conform to Twitch's login alphabet; see
  /// `archives(forLogin:limit:)` for the full safety contract.
  static func profileQuery(login: String) -> String {
    """
    query { user(login: "\(login)") { displayName \
    profileImageURL(width: \(avatarWidth)) } }
    """
  }

  /// Shared extraction of `data.user`, distinguishing malformed responses, integrity
  /// challenges, and unknown logins.
  private static func user(from data: Data) throws -> [String: Any] {
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
    guard let user = payload["user"] as? [String: Any] else {
      throw ChannelFeedError.malformedPayload(snippet: snippet(data))
    }
    return user
  }

  private static func decodeProfile(_ data: Data) throws -> ChannelProfile {
    let user = try user(from: data)
    guard let displayName = user["displayName"] as? String else {
      throw ChannelFeedError.malformedPayload(snippet: snippet(data))
    }
    // A missing avatar is optional, not a failed profile.
    let avatar = (user["profileImageURL"] as? String).flatMap(URL.init(string:))
    return ChannelProfile(displayName: displayName, avatarURL: avatar)
  }

  private static func decode(_ data: Data) throws -> [ChannelArchive] {
    guard
      let videos = try user(from: data)["videos"] as? [String: Any],
      let edges = videos["edges"] as? [[String: Any]]
    else { throw ChannelFeedError.malformedPayload(snippet: snippet(data)) }

    let formatter = ISO8601DateFormatter()
    let archives = edges.compactMap { edge -> ChannelArchive? in
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
        thumbnailURL: (node["previewThumbnailURL"] as? String).flatMap(URL.init(string:)),
        categoryName: (node["game"] as? [String: Any])?["name"] as? String,
        categoryArtURL: ((node["game"] as? [String: Any])?["boxArtURL"] as? String)
          .flatMap(URL.init(string:)))
    }

    // Nonempty edges with no decodable archives indicate format drift, not an empty channel.
    // Silently returning [] would make “Only new” seed against an invalid result. Genuinely
    // empty edges remain valid.
    guard edges.isEmpty || archives.count == edges.count else {
      throw ChannelFeedError.malformedPayload(snippet: snippet(data))
    }
    return archives
  }

  /// Bound raw bytes before decoding and mark truncation so the snippet cannot be mistaken for
  /// the full response.
  private static func snippet(_ data: Data) -> String {
    guard data.count > snippetLimit else {
      return String(decoding: data, as: UTF8.self)
    }
    let truncated = String(decoding: data.prefix(snippetLimit), as: UTF8.self)
    return "\(truncated)… [truncated, \(data.count) bytes total]"
  }
}
