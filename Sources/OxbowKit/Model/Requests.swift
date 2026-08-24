import Foundation

public enum ChatFormat: String, Codable, Sendable, Equatable {
  case json, text, html
}

public struct VideoRequest: Codable, Sendable, Equatable {
  public var videoID: String
  public var quality: String
  public var trimStart: Duration?
  public var trimEnd: Duration?
  public var destination: URL

  public init(
    videoID: String,
    quality: String,
    trimStart: Duration? = nil,
    trimEnd: Duration? = nil,
    destination: URL)
  {
    self.videoID = videoID
    self.quality = quality
    self.trimStart = trimStart
    self.trimEnd = trimEnd
    self.destination = destination
  }
}

public struct ClipRequest: Codable, Sendable, Equatable {
  public var clipSlug: String
  public var quality: String
  public var destination: URL

  public init(clipSlug: String, quality: String, destination: URL) {
    self.clipSlug = clipSlug
    self.quality = quality
    self.destination = destination
  }
}

public struct ChatRequest: Codable, Sendable, Equatable {
  /// A VOD id or a clip slug — upstream's `chatdownload --id` documents
  /// itself as taking "a VOD or clip" and accepts either into this same
  /// parameter (design doc §8). The field predates clip support; a rename
  /// is a wider change than the task that added it made.
  public var videoID: String
  public var trimStart: Duration?
  public var trimEnd: Duration?
  public var format: ChatFormat
  public var isEmbeddingImages: Bool
  /// `nil` means the user does not want to keep the chat file, so it stays in
  /// the job workspace and is discarded with it. This is the queue half of the
  /// open question in the design spec, §10.
  public var destination: URL?

  public init(
    videoID: String,
    trimStart: Duration? = nil,
    trimEnd: Duration? = nil,
    format: ChatFormat,
    isEmbeddingImages: Bool = false,
    destination: URL? = nil)
  {
    self.videoID = videoID
    self.trimStart = trimStart
    self.trimEnd = trimEnd
    self.format = format
    self.isEmbeddingImages = isEmbeddingImages
    self.destination = destination
  }
}

public struct RenderRequest: Codable, Sendable, Equatable {
  public var width: Int
  public var height: Int
  public var framerate: Int
  public var fontSize: Double
  public var font: String
  public var backgroundColor: String
  public var alternateBackgroundColor: String
  public var messageColor: String
  public var hasBadges: Bool
  public var hasTimestamps: Bool
  public var hasSubMessages: Bool
  public var hasOutline: Bool
  public var outlineSize: Int
  /// Surfaced deliberately, not left as invisible defaults: 7TV resolution is
  /// why the submodule is pinned past 1.56.5 (CLAUDE.md), so the switch that
  /// controls it should be visible and user-controllable.
  public var isBTTVEnabled: Bool
  public var isFFZEnabled: Bool
  public var isSTVEnabled: Bool
  public var allowsUnlistedEmotes: Bool
  /// VideoToolbox is bitrate-targeted; there is no CRF equivalent.
  /// See docs/ffmpeg.md, section 3.
  public var bitrateMbps: Int
  public var isSharpened: Bool
  public var destination: URL

  public init(
    width: Int = 350,
    height: Int = 600,
    framerate: Int = 30,
    fontSize: Double = 12,
    font: String = "Inter Embedded",
    backgroundColor: String = "#111111",
    alternateBackgroundColor: String = "#191919",
    messageColor: String = "#ffffff",
    hasBadges: Bool = true,
    hasTimestamps: Bool = false,
    hasSubMessages: Bool = true,
    hasOutline: Bool = false,
    outlineSize: Int = 4,
    isBTTVEnabled: Bool = true,
    isFFZEnabled: Bool = true,
    isSTVEnabled: Bool = true,
    allowsUnlistedEmotes: Bool = true,
    bitrateMbps: Int = 3,
    isSharpened: Bool = false,
    destination: URL)
  {
    self.width = width
    self.height = height
    self.framerate = framerate
    self.fontSize = fontSize
    self.font = font
    self.backgroundColor = backgroundColor
    self.alternateBackgroundColor = alternateBackgroundColor
    self.messageColor = messageColor
    self.hasBadges = hasBadges
    self.hasTimestamps = hasTimestamps
    self.hasSubMessages = hasSubMessages
    self.hasOutline = hasOutline
    self.outlineSize = outlineSize
    self.isBTTVEnabled = isBTTVEnabled
    self.isFFZEnabled = isFFZEnabled
    self.isSTVEnabled = isSTVEnabled
    self.allowsUnlistedEmotes = allowsUnlistedEmotes
    self.bitrateMbps = bitrateMbps
    self.isSharpened = isSharpened
    self.destination = destination
  }
}
