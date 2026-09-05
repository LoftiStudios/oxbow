import Foundation

/// A watched channel.
///
/// **The settings are frozen, not a live reference to `Preferences`.** An
/// intake window re-reads the store at every open because it *has* an open
/// moment to re-read at; a watch fires months later with nobody present, so
/// freezing is the only predictable option. See
/// `docs/design/channel-watching.md` §3.2, and `settings.md` §10.5 for the
/// same reasoning applied to the window.
public struct Watch: Equatable, Sendable, Codable {

  /// What this channel downloads at, decided when it was added.
  ///
  /// The destination is a path rather than a `URL` because it is persisted:
  /// `URL`'s `Codable` form carries more than a path and round-trips
  /// inconsistently across its representations.
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

  /// How the seen-set is seeded when a channel is added.
  ///
  /// **Not stored.** Scope is not a mode the poller consults forever after —
  /// it only decides what `seeded(withScope:from:)` puts in `seen` at the
  /// moment of adding. After the first poll the two choices are
  /// indistinguishable (`docs/design/channel-watching.md` §3.1).
  public enum Scope: Equatable, Sendable {
    case onlyNew
    case allAvailable
  }

  public var login: String
  public var displayName: String
  public var settings: Settings
  public var downloadsAutomatically: Bool

  /// Archive ids this watch has acted on — queued, ignored, or seeded past.
  ///
  /// **Its own state, never derived from the queue.**
  /// `IntentSubmission.submit` refuses duplicates only against *unfinished*
  /// jobs, deliberately, and `QueueEngine.remove(jobs:)` can delete a job
  /// outright. A watcher deriving from either would re-download what it has
  /// already fetched (`docs/design/channel-watching.md` §4).
  public var seen: Set<String>

  public init(
    login: String, displayName: String, settings: Settings,
    downloadsAutomatically: Bool, seen: Set<String>)
  {
    self.login = login
    self.displayName = displayName
    self.settings = settings
    self.downloadsAutomatically = downloadsAutomatically
    self.seen = seen
  }

  /// First path segments that address something other than a channel.
  /// `videos`, `directory`, `settings`, `popout`, `subscriptions`,
  /// `downloads`, `clips`, `u` and `team` are all reserved routes on
  /// twitch.tv — a URL that starts with one of them is not a channel URL,
  /// and taking its first segment anyway hands back a route name dressed up
  /// as a login (`https://twitch.tv/videos/2862926638` → `"videos"`).
  private static let reservedFirstPathSegments: Set<String> = [
    "videos", "directory", "settings", "popout", "subscriptions",
    "downloads", "clips", "u", "team",
  ]

  /// Twitch logins are 4-25 characters of `[a-zA-Z0-9_]`. Anything else is
  /// rejected rather than cleaned up.
  ///
  /// **This is a safety boundary, not a convenience.** The login is
  /// interpolated into the GraphQL query body, so a string carrying a quote
  /// or a brace would rewrite the query. Rejecting is the only correct
  /// answer for that. Separately, this takes the same posture
  /// `TwitchLink.parse` takes about *hosts* — an unrecognised or
  /// case-varied host is rejected, not guessed at — but not the same
  /// posture about *paths*: `TwitchLink.parse` matches a small set of known
  /// path shapes and rejects everything else, where this only excludes
  /// Twitch's reserved routes (`reservedFirstPathSegments`) and the
  /// `clips.twitch.tv` host, and otherwise takes the first path segment as
  /// a login. That asymmetry is deliberate — a channel URL's shape is not
  /// as constrained as a video or clip URL's — but it means the two
  /// parsers can still disagree on inputs neither list anticipates.
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

  /// A copy whose seen-set has been initialised for `scope`.
  ///
  /// Seeds from **every** listed archive, including one still recording: for
  /// `onlyNew` the promise is that nothing already on the channel appears,
  /// and a live broadcast skipped here would arrive as brand new the moment
  /// it ended.
  public func seeded(withScope scope: Scope, from archives: [ChannelArchive]) -> Watch {
    switch scope {
    case .onlyNew: marking(archives.map(\.id))
    case .allAvailable: self
    }
  }

  /// Archives in `listing` this watch has not acted on.
  ///
  /// Deliberately does **not** filter on `isDownloadable`: a person may
  /// reasonably be shown a live broadcast, clearly marked. Only the
  /// unattended path filters (`docs/design/channel-watching.md` §5.2), and it
  /// does so at the point of submission.
  public func findings(in listing: [ChannelArchive]) -> [ChannelArchive] {
    listing.filter { !seen.contains($0.id) }
  }

  public func marking(_ ids: some Sequence<String>) -> Watch {
    var copy = self
    copy.seen.formUnion(ids)
    return copy
  }
}
