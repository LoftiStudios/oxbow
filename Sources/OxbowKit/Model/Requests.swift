import Foundation

public enum ChatFormat: String, Codable, Sendable, Equatable {
  case json, text, html
}

public struct VideoRequest: Codable, Sendable, Equatable {
  public var videoID: String
  public var quality: String
  public var trimStart: Duration?
  public var trimEnd: Duration?
  /// Nil keeps the file in the workspace as an intermediate, discarded with the job.
  public var destination: URL?

  public init(
    videoID: String,
    quality: String,
    trimStart: Duration? = nil,
    trimEnd: Duration? = nil,
    destination: URL? = nil)
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
  /// Nil keeps the file in the workspace as an intermediate, discarded with the job.
  public var destination: URL?

  public init(clipSlug: String, quality: String, destination: URL? = nil) {
    self.clipSlug = clipSlug
    self.quality = quality
    self.destination = destination
  }
}

public struct ChatRequest: Codable, Sendable, Equatable {
  /// A VOD ID or clip slug; `chatdownload --id` accepts either.
  public var videoID: String
  public var trimStart: Duration?
  public var trimEnd: Duration?
  public var format: ChatFormat
  public var isEmbeddingImages: Bool
  /// Nil keeps chat in the workspace as an intermediate, discarded with the job.
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

/// Joins composite pieces for delivery. Runs even for one piece so all composites share the
/// same delivery path.
public struct AssembleRequest: Codable, Sendable, Equatable {
  public var destination: URL

  public init(destination: URL) {
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
  /// Requires `hasAlternateBackgrounds`; the CLI ignores this color unless alternate
  /// backgrounds are enabled.
  public var alternateBackgroundColor: String
  public var hasAlternateBackgrounds: Bool
  public var messageColor: String
  public var hasTimestamps: Bool
  public var hasOutline: Bool
  public var outlineSize: Int
  /// VideoToolbox is bitrate-targeted; there is no CRF equivalent.
  /// See docs/ffmpeg.md, section 3.
  public var bitrateMbps: Int
  public var isSharpened: Bool
  /// Nil keeps the file in the workspace as an intermediate, discarded with the job.
  public var destination: URL?

  public init(
    width: Int = 350,
    height: Int = 600,
    framerate: Int = 30,
    fontSize: Double = 12,
    font: String = "Inter Embedded",
    backgroundColor: String = "#111111",
    alternateBackgroundColor: String = "#191919",
    hasAlternateBackgrounds: Bool = false,
    messageColor: String = "#ffffff",
    hasTimestamps: Bool = false,
    hasOutline: Bool = false,
    outlineSize: Int = 4,
    bitrateMbps: Int = 3,
    isSharpened: Bool = false,
    destination: URL? = nil)
  {
    self.width = width
    self.height = height
    self.framerate = framerate
    self.fontSize = fontSize
    self.font = font
    self.backgroundColor = backgroundColor
    self.alternateBackgroundColor = alternateBackgroundColor
    self.hasAlternateBackgrounds = hasAlternateBackgrounds
    self.messageColor = messageColor
    self.hasTimestamps = hasTimestamps
    self.hasOutline = hasOutline
    self.outlineSize = outlineSize
    self.bitrateMbps = bitrateMbps
    self.isSharpened = isSharpened
    self.destination = destination
  }
}
