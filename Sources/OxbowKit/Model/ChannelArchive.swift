import Foundation

/// Transient channel-feed archive. Durable history is represented separately by VideoRecord.
public struct ChannelArchive: Equatable, Sendable {

  /// Preserve unknown statuses without failing a page, but only recorded is safe for unattended
  /// download.
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

  /// What Twitch's category was set to for this broadcast — "ELDEN RING",
  /// "Just Chatting". Nil when the node carried no category at all.
  public let categoryName: String?

  /// Fetch category art alongside video thumbnails in the same query; presentation chooses
  /// which to show.
  public let categoryArtURL: URL?

  public init(
    id: String, title: String, duration: Duration,
    publishedAt: Date, status: Status, thumbnailURL: URL?,
    categoryName: String? = nil, categoryArtURL: URL? = nil)
  {
    self.categoryName = categoryName
    self.categoryArtURL = categoryArtURL
    self.id = id
    self.title = title
    self.duration = duration
    self.publishedAt = publishedAt
    self.status = status
    self.thumbnailURL = thumbnailURL
  }

  /// Only completed recordings are safe unattended; the newest feed item may still be
  /// broadcasting.
  public var isDownloadable: Bool { status == .recorded }
}
