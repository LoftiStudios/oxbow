import Foundation

/// A channel watch with frozen download settings; later changes to Preferences do not alter
/// unattended downloads.
public struct Watch: Equatable, Sendable, Codable {

  /// Settings captured when the watch was added. Persist destination as a path string.
  public struct Settings: Equatable, Sendable, Codable {
    public var destinationPath: String
    public var qualityCap: QualityCap
    public var output: DownloadOutput
    public var chatSize: ChatSize

    public init(
      destinationPath: String, qualityCap: QualityCap,
      output: DownloadOutput, chatSize: ChatSize)
    {
      self.destinationPath = destinationPath
      self.qualityCap = qualityCap
      self.output = output
      self.chatSize = chatSize
    }

    public var destination: URL { URL(filePath: destinationPath) }
  }

  /// Initial seeding choice, not an ongoing poll mode. Used only when the watch is added.
  public enum Scope: Equatable, Sendable {
    case onlyNew
    case allAvailable
  }

  public var login: String
  public var displayName: String

  /// Avatar captured when added. Optional for older persisted watches; polls do not refresh
  /// channel profiles.
  public var avatarURL: URL?
  public var settings: Settings
  public var downloadsAutomatically: Bool

  /// Legacy handled IDs, independent of the queue: completed or removed jobs must not become
  /// eligible for automatic download again.
  public var seen: Set<String>

  public init(
    login: String, displayName: String, settings: Settings,
    downloadsAutomatically: Bool, seen: Set<String>, avatarURL: URL? = nil)
  {
    self.login = login
    self.displayName = displayName
    self.avatarURL = avatarURL
    self.settings = settings
    self.downloadsAutomatically = downloadsAutomatically
    self.seen = seen
  }

  /// Reserved Twitch routes that must not be interpreted as channel logins (e.g.
  /// `/videos/123`).
  private static let reservedFirstPathSegments: Set<String> = [
    "videos", "directory", "settings", "popout", "subscriptions",
    "downloads", "clips", "u", "team",
  ]

  /// Accepts 4–25 ASCII letters, digits, or underscores. Reject invalid input: the login is
  /// interpolated into GraphQL. For URLs, validate the host and exclude reserved routes, then
  /// use the first path segment.
  public static func normalisedLogin(_ raw: String) -> String? {
    var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)

    if text.contains("/") {
      let candidate = text.contains("://") ? text : "https://\(text)"
      guard
        let components = URLComponents(string: candidate),
        let host = components.host?.lowercased(),
        host != "clips.twitch.tv",
        host == "twitch.tv" || host.hasSuffix(".twitch.tv"),
        let first = components.path.split(separator: "/").first,
        !reservedFirstPathSegments.contains(first.lowercased())
      else { return nil }
      text = String(first)
    }

    let login = text.lowercased()
    guard (4...25).contains(login.count),
          login.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") })
    else { return nil }
    return login
  }

  /// Seeds from every listed archive, including live broadcasts, so “Only new” cannot admit an
  /// existing broadcast when it ends.
  public func seeded(withScope scope: Scope, from archives: [ChannelArchive]) -> Watch {
    switch scope {
    case .onlyNew: marking(archives.map(\.id))
    case .allAvailable: self
    }
  }

  /// Unseen archives, including live broadcasts for display. The unattended submission path
  /// filters downloadability.
  public func findings(in listing: [ChannelArchive]) -> [ChannelArchive] {
    listing.filter { !seen.contains($0.id) }
  }

  public func marking(_ ids: some Sequence<String>) -> Watch {
    var copy = self
    copy.seen.formUnion(ids)
    return copy
  }

  /// Removes failed automatic downloads from seen IDs so they return to the inbox for retry.
  public func forgetting(_ ids: some Sequence<String>) -> Watch {
    var copy = self
    copy.seen.subtract(ids)
    return copy
  }
}
