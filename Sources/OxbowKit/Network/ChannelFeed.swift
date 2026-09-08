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
  /// The request never reached Twitch at all — offline, DNS, TLS. Distinct
  /// from `.server(status:)`, which blames Twitch for the user's wifi, and
  /// from `.malformedPayload`, which would blame Twitch for a response that
  /// never arrived.
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

  /// How much of an unreadable payload `.malformedPayload` keeps, in bytes
  /// of the raw response — truncated before UTF-8 decoding, not after, so a
  /// runaway response cannot balloon the intermediate string either. Not
  /// private: the test pins it.
  static let snippetLimit = 280

  /// The largest page the server will serve, stated by the server itself:
  /// "argument 'first' value must be between 1 and 100."
  public static let maximumLimit = 100

  /// The avatar size asked of `profileImageURL`.
  ///
  /// **A member of a fixed set, not a number derived from a layout.**
  /// `docs/twitch-channel-api.md` §9.2 measures it: the field accepts any
  /// width and builds a CDN filename by interpolation, so an unserved size
  /// comes back as a perfectly ordinary URL that 404s at fetch time. The CDN
  /// serves 28, 50, 70, 150, 300 and 600 — 100, 200, 400 and 1200 do not
  /// exist. 300 covers a 150pt avatar at 2x at about 150 KB; 600 is the next
  /// rung up and nearly 550 KB.
  public static let avatarWidth = 300

  /// The category box art's size, in the 3:4 shape Twitch's own art uses.
  ///
  /// **Unlike `avatarWidth`, this one is not a member of a fixed set.** The
  /// box-art CDN resizes on demand — 52x72, 144x192, 188x250, 285x380 and
  /// 300x400 all served when probed, including sizes Twitch's own site never
  /// asks for. So this is chosen for the view (a 48pt-wide row thumbnail at
  /// 2x, with room to spare) rather than picked off a list, and changing it
  /// does not risk the silent 404 `docs/twitch-channel-api.md` §9.2
  /// describes for avatars.
  ///
  /// Asked for *with* arguments, for the reason §8 gives about
  /// `previewThumbnailURL`: bare, it answers with a literal
  /// `{width}x{height}` in the URL.
  public static let categoryArtWidth = 144
  public static let categoryArtHeight = 192

  private let fetch: Fetch
  private let endpoint: URL

  public init(fetch: @escaping Fetch, endpoint: URL = ChannelFeed.defaultEndpoint) {
    self.fetch = fetch
    self.endpoint = endpoint
  }

  /// The `login` parameter is interpolated unescaped into a GraphQL query
  /// string. An invalid login containing quote characters would break out of
  /// the string literal and rewrite the query. Callers must ensure logins
  /// conform to Twitch's own login alphabet; `Watch.normalisedLogin(_:)`
  /// enforces this contract, and callers should route logins through it
  /// rather than constructing their own.
  public func archives(forLogin login: String, limit: Int = maximumLimit)
    async throws -> [ChannelArchive]
  {
    let (data, response) = try await fetch(request(query: Self.query(login: login, limit: limit)))
    guard response.statusCode == 200 else {
      throw ChannelFeedError.server(status: response.statusCode)
    }
    return try Self.decode(data)
  }

  /// The channel's own metadata: the name cased however its owner set it —
  /// `"Ninja"` where `login` is `"ninja"` — and its avatar.
  ///
  /// **Its own request, not a field folded into `archives(forLogin:
  /// limit:)`.** That query is also `WatchPoll.sweep`'s injected fetch
  /// closure's signature, wired through `WatchPoller`; widening it would
  /// ripple into both and would put an avatar fetch on every poll of every
  /// channel, forever, for two values that change about never. A poll
  /// already has the display name from the stored `Watch`. This round trip
  /// is paid only when a channel is added.
  ///
  /// `login` carries the same safety contract as `archives(forLogin:
  /// limit:)`: it is interpolated unescaped into the query body, so route it
  /// through `Watch.normalisedLogin(_:)` first.
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

  /// **`previewThumbnailURL` takes arguments and must be given them.** Asked
  /// for bare it returns a URL containing a literal `{width}x{height}`, which
  /// `StreamThumbnail.rewritten(_:)` cannot match — so a bare request would
  /// flow an unusable URL straight through into a 404
  /// (`docs/twitch-channel-api.md` §8). 320x180 matches what the intake
  /// already fetches and rewrites.
  ///
  /// `login` must conform to Twitch's login alphabet; see
  /// `archives(forLogin:limit:)` for the full safety contract.
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

  /// The `data.user` object, having already ruled out the shared failure
  /// modes both queries in this file can hit: an unparseable body, an
  /// integrity challenge, and an explicit null user for an unknown login.
  /// Shared so `decode(_:)` and `decodeProfile(_:)` cannot drift on how
  /// either is recognised.
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
    // A missing avatar is a channel without one, not a broken payload, so it
    // degrades to nil rather than failing the whole call.
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

    // `docs/design/channel-watching.md` §7: "a parse that fails degrades the
    // watch to a visible error rather than to an empty list that looks like
    // 'no new videos'." A renamed field or a timestamp format
    // `ISO8601DateFormatter()` no longer accepts would make every closure
    // above return nil, and `compactMap` would silently swallow every one of
    // them — indistinguishable here from a channel with nothing new, and
    // catastrophic combined with `Watch.seeded(withScope: .onlyNew, from:
    // [])`, which trusts an empty result to mean "nothing to seed against".
    // An empty `edges` is not a parse failure and must still succeed.
    guard edges.isEmpty || archives.count == edges.count else {
      throw ChannelFeedError.malformedPayload(snippet: snippet(data))
    }
    return archives
  }

  /// Truncates `data` to `snippetLimit` bytes before any string conversion,
  /// so a runaway response cannot balloon the intermediate allocation any
  /// more than it can balloon the error string itself — then leaves the same
  /// visible marker `VideoInfoFetchError` does, so the snippet is never
  /// mistaken for the whole payload.
  private static func snippet(_ data: Data) -> String {
    guard data.count > snippetLimit else {
      return String(decoding: data, as: UTF8.self)
    }
    let truncated = String(decoding: data.prefix(snippetLimit), as: UTF8.self)
    return "\(truncated)… [truncated, \(data.count) bytes total]"
  }
}
