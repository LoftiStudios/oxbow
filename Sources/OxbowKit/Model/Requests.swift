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
    bitrateMbps: Int = 3,
    isSharpened: Bool = false,
    destination: URL)
  {
    self.width = width
    self.height = height
    self.framerate = framerate
    self.fontSize = fontSize
    self.bitrateMbps = bitrateMbps
    self.isSharpened = isSharpened
    self.destination = destination
  }
}
