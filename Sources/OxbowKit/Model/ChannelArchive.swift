import Foundation

/// One archive from a channel's video list, as the app understands it.
///
/// **Not `Codable`, deliberately.** The inbox is derived on every poll from
/// the feed minus the watch's seen-set (`docs/design/channel-watching.md` §4),
/// so an archive is fetched and displayed but never written. A stored one
/// would outlive its own expiry and show a row nothing can download.
public struct ChannelArchive: Equatable, Sendable {

  /// Twitch's `status`, kept as a closed set plus an escape hatch.
  ///
  /// `other` exists because the schema cannot be introspected
  /// (`docs/twitch-channel-api.md` §7): a value we have never seen must
  /// decode to *something* rather than fail the whole page, and it must not
  /// be assumed safe. `isDownloadable` therefore allows only `recorded`.
  public enum Status: Equatable, Sendable {
    case recorded
    case recording
    case other(String)

    public init(rawValue: String) {
      switch rawValue {
      case "RECORDED": self = .recorded
      case "RECORDING": self = .recording
      default: self = .other(rawValue)
      }
    }
  }

  public let id: String
  public let title: String
  public let duration: Duration
  public let publishedAt: Date
  public let status: Status
  public let thumbnailURL: URL?

  public init(
    id: String, title: String, duration: Duration,
    publishedAt: Date, status: Status, thumbnailURL: URL?)
  {
    self.id = id
    self.title = title
    self.duration = duration
    self.publishedAt = publishedAt
    self.status = status
    self.thumbnailURL = thumbnailURL
  }

  /// Whether anything unattended may queue this.
  ///
  /// A live broadcast is listed as a video and is the *newest* item, so it is
  /// exactly what a "has anything appeared?" poll finds first — and what it
  /// would download is a partial stream whose chat is not final
  /// (`docs/design/channel-watching.md` §5.2).
  public var isDownloadable: Bool { status == .recorded }
}
