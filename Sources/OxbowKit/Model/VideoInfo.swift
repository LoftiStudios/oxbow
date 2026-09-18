import Foundation

/// One downloadable rendition from the VOD's m3u8 master playlist.
public struct StreamQuality: Sendable, Equatable, Codable {
  public var name: String
  public var resolution: String
  public var bitsPerSecond: Int

  public init(name: String, resolution: String, bitsPerSecond: Int) {
    self.name = name
    self.resolution = resolution
    self.bitsPerSecond = bitsPerSecond
  }

  /// Rough output size for this quality over `duration`, from bitrate alone.
  public func estimatedBytes(over duration: Duration) -> Int {
    Int(Double(bitsPerSecond) * duration.asSeconds / 8)
  }

  /// Reported dimensions, or nil when absent (including older clips). Shared by geometry and
  /// quality selection.
  public var pixelSize: (width: Int, height: Int)? {
    let parts = resolution.split(separator: "x")
    guard parts.count == 2,
          let width = Int(parts[0]), let height = Int(parts[1]),
          width > 0, height > 0
    else { return nil }
    return (width, height)
  }

  /// Orientation-independent quality size: `1080p60-Portrait` is 1080x1920, so its 1080p tier
  /// comes from width rather than height.
  public var shortSide: Int? {
    guard let size = pixelSize else { return nil }
    return min(size.width, size.height)
  }

  /// CLI quality value: strips a numeric suffix only when the remainder is a bare quality name
  /// (e.g. `480p30-1` → `480p30`). Preserves portrait suffixes and frame-rate digits such as
  /// `720p0`. TODO: reconcile this behavior with `docs/twitch-metadata.md` §5, which retracts
  /// the original diagnosis and says valid duplicate suffixes must be preserved. Unknown names
  /// silently select the best rendition.
  public var commandLineValue: String {
    guard let hyphenIndex = name.lastIndex(of: "-") else { return name }
    let suffix = name[name.index(after: hyphenIndex)...]
    guard !suffix.isEmpty, suffix.allSatisfy(\.isNumber) else { return name }
    let remainder = name[name.startIndex..<hyphenIndex]
    guard remainder.range(of: #"^\d{3,4}p\d{1,3}$"#, options: .regularExpression) != nil else {
      return name
    }
    return String(remainder)
  }
}

/// Metadata from CLI `info --format Raw`; JSON format is unimplemented upstream. VOD output
/// contains video JSON, moments JSON, then an m3u8 playlist. Clips contain one JSON object with
/// qualities under `assets[].videoQualities`.
public struct VideoInfo: Sendable, Equatable {
  public var streamer: String
  /// Channel join key. Never derive it from the display name: the two may use different
  /// scripts. Nil leaves the record unassociated with a watched channel.
  public var login: String?
  public var title: String
  public var createdAt: Date
  public var duration: Duration
  public var qualities: [StreamQuality]
  /// Preview frames in Twitch's order: four sampled VOD images, one clip thumbnail. May be
  /// empty while processing or when assets are absent. See `StreamThumbnail` for VOD size
  /// rewriting.
  public var thumbnailURLs: [URL]

  /// First available preview, for surfaces that show a single image.
  public var thumbnailURL: URL? { thumbnailURLs.first }

  /// Uses the chat downloader's own predicate: clips need both a parent video and
  /// `videoOffsetSeconds`. False rules out chat; true may become stale before execution, so
  /// runtime failure handling is still required. VODs default to true. See
  /// `docs/twitch-metadata.md` §6.
  public var hasDownloadableChat: Bool

  public init(
    streamer: String,
    login: String? = nil,
    title: String,
    createdAt: Date,
    duration: Duration,
    qualities: [StreamQuality],
    thumbnailURLs: [URL] = [],
    hasDownloadableChat: Bool = true)
  {
    self.streamer = streamer
    self.login = login
    self.title = title
    self.createdAt = createdAt
    self.duration = duration
    self.qualities = qualities
    self.thumbnailURLs = thumbnailURLs
    self.hasDownloadableChat = hasDownloadableChat
  }

  public static func parse(_ output: String) -> VideoInfo? {
    let lines = output.split(separator: "\n", omittingEmptySubsequences: false)

    guard let jsonLineIndex = lines.firstIndex(where: isJSONObjectLine),
          let jsonData = lines[jsonLineIndex].data(using: .utf8)
    else { return nil }

    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601

    // VOD and clip envelopes have distinct keys; try the more common VOD shape first.
    if let envelope = try? decoder.decode(VideoInfoEnvelope.self, from: jsonData) {
      let video = envelope.data.video
      return VideoInfo(
        streamer: video.owner.displayName,
        login: video.owner.login,
        title: video.title,
        createdAt: video.createdAt,
        duration: .seconds(video.lengthSeconds),
        // The m3u8 master playlist follows the JSON lines, and only for a VOD.
        qualities: Self.parseQualities(from: lines[(jsonLineIndex + 1)...]),
        // Skip malformed preview URLs without discarding the video's metadata.
        thumbnailURLs: (video.thumbnailURLs ?? []).compactMap(URL.init(string:)))
    }

    if let envelope = try? decoder.decode(ClipInfoEnvelope.self, from: jsonData) {
      let clip = envelope.data.clip
      return VideoInfo(
        streamer: clip.broadcaster.displayName,
        login: clip.broadcaster.login,
        title: clip.title,
        createdAt: clip.createdAt,
        duration: .seconds(clip.durationSeconds),
        qualities: Self.clipQualities(of: clip),
        // Clips expose one thumbnail, not a sampled list.
        thumbnailURLs: Self.clipThumbnailURL(of: clip).map { [$0] } ?? [],
        // Match upstream's check of both parent video and offset.
        hasDownloadableChat: clip.video != nil && clip.videoOffsetSeconds != nil)
    }

    return nil
  }

  /// A cheap pre-check so we don't try to JSON-decode m3u8/status lines: real
  /// JSON objects here always start with `{`.
  private static func isJSONObjectLine(_ line: Substring) -> Bool {
    line.first == "{"
  }

  private static func parseQualities<S: Sequence<Substring>>(from lines: S) -> [StreamQuality] {
    var qualities: [StreamQuality] = []
    for line in lines where line.hasPrefix("#EXT-X-STREAM-INF:") {
      let attributesText = line.dropFirst("#EXT-X-STREAM-INF:".count)
      let attributes = Self.parseAttributes(attributesText)

      guard let resolution = attributes["RESOLUTION"] else { continue }
      guard let bandwidthText = attributes["BANDWIDTH"], let bandwidth = Int(bandwidthText) else {
        continue
      }
      let name = attributes["STABLE-VARIANT-ID"] ?? resolution

      qualities.append(StreamQuality(name: name, resolution: resolution, bitsPerSecond: bandwidth))
    }
    return qualities
  }

  /// Reproduces upstream quality names and ordering: rounded frame rate, optional `-Portrait`,
  /// numbered duplicates, landscape first. Unknown CLI names silently select best quality, so
  /// preserve upstream suffixes. Collapse otherwise identical renditions while retaining the
  /// first disambiguated name; see `commandLineValue` for CLI normalization.
  private static func clipQualities(of clip: ClipInfoEnvelope.ClipEnvelope) -> [StreamQuality] {
    struct Rendition {
      var name: String
      var isPortrait: Bool
      var height: Int
      var frameRate: Double
      var bitsPerSecond: Int
      var resolution: String
      /// Identity for the duplicate collapse: everything about the rendition
      /// except the `-N` upstream appended to tell copies apart.
      var fingerprint: String
    }

    var renditions: [Rendition] = []
    for asset in clip.assets ?? [] {
      let aspectRatio = asset.aspectRatio ?? 0
      let isPortrait = asset.isPortrait
      for quality in asset.videoQualities ?? [] {
        guard let frameHeight = quality.quality, !frameHeight.isEmpty else { continue }
        let (width, height) = Self.clipResolution(of: quality, aspectRatio: aspectRatio)
        let baseName =
          "\(frameHeight)p\(Int(quality.frameRate.rounded()))"
          + (isPortrait ? "-Portrait" : "")
        renditions.append(Rendition(
          name: baseName,
          isPortrait: isPortrait,
          height: height,
          frameRate: quality.frameRate,
          bitsPerSecond: quality.bitrate,
          resolution: width > 0 ? "\(width)x\(height)" : (height > 0 ? "\(height)" : ""),
          fingerprint: "\(baseName)|\(width)x\(height)|\(quality.bitrate)"))
      }
    }

    // Upstream's disambiguation, over the whole list: a name seen more than
    // once has every occurrence suffixed, starting at `-1`.
    var repeated: Set<String> = []
    var seen: Set<String> = []
    for rendition in renditions {
      if !seen.insert(rendition.name).inserted { repeated.insert(rendition.name) }
    }
    var nextSuffix: [String: Int] = [:]
    for index in renditions.indices where repeated.contains(renditions[index].name) {
      let base = renditions[index].name
      let suffix = (nextSuffix[base] ?? 0) + 1
      nextSuffix[base] = suffix
      renditions[index].name = "\(base)-\(suffix)"
    }

    var emitted: Set<String> = []
    let unique = renditions.filter { emitted.insert($0.fingerprint).inserted }

    // Sorted on the original index last so the order is total: `sorted(by:)`
    // is not documented as stable, and two renditions can tie on every other
    // key.
    return unique.enumerated()
      .sorted { left, right in
        let (a, b) = (left.element, right.element)
        if a.isPortrait != b.isPortrait { return !a.isPortrait }
        if a.height != b.height { return a.height > b.height }
        if a.frameRate != b.frameRate { return a.frameRate > b.frameRate }
        if a.name != b.name { return a.name > b.name }
        return left.offset < right.offset
      }
      .map {
        StreamQuality(
          name: $0.element.name,
          resolution: $0.element.resolution,
          bitsPerSecond: $0.element.bitsPerSecond)
      }
  }

  /// Prefer the first landscape asset's preview, falling back to any asset for portrait-only
  /// clips.
  private static func clipThumbnailURL(of clip: ClipInfoEnvelope.ClipEnvelope) -> URL? {
    let assets = clip.assets ?? []
    let preferred = assets.first { !$0.isPortrait && $0.thumbnailURL != nil }
      ?? assets.first { $0.thumbnailURL != nil }
    return preferred?.thumbnailURL.flatMap(URL.init(string:))
  }

  /// Upstream's `BuildClipResolution`: the explicit pixel dimensions when the
  /// payload has them, and otherwise the `quality` string read as a height
  /// with the asset's aspect ratio supplying the width. Older clips carry
  /// zeroes for width, height, bitrate and framerate alike.
  private static func clipResolution(
    of quality: ClipInfoEnvelope.ClipQualityEnvelope,
    aspectRatio: Double)
    -> (width: Int, height: Int)
  {
    if quality.width > 0 && quality.height > 0 { return (quality.width, quality.height) }
    guard let text = quality.quality, let height = Int(text), height > 0 else { return (0, 0) }
    guard aspectRatio > 0 else { return (0, height) }
    return (Int((Double(height) * aspectRatio).rounded()), height)
  }

  /// Splits playlist attributes on unquoted commas. `CODECS="avc1.640029,mp4a.40.2"` must
  /// remain one attribute.
  private static func parseAttributes(_ text: Substring) -> [String: String] {
    var result: [String: String] = [:]

    var fieldStart = text.startIndex
    var insideQuotes = false
    var index = text.startIndex

    func commitField(endingAt end: String.Index) {
      let field = text[fieldStart..<end]
      guard let equalsIndex = field.firstIndex(of: "=") else { return }
      let key = field[field.startIndex..<equalsIndex]
      var value = field[field.index(after: equalsIndex)...]
      if value.first == "\"", value.last == "\"", value.count >= 2 {
        value = value.dropFirst().dropLast()
      }
      result[String(key)] = String(value)
    }

    while index < text.endIndex {
      let character = text[index]
      if character == "\"" {
        insideQuotes.toggle()
      } else if character == "," && !insideQuotes {
        commitField(endingAt: index)
        fieldStart = text.index(after: index)
      }
      index = text.index(after: index)
    }
    commitField(endingAt: text.endIndex)

    return result
  }
}

/// Mirrors just the fields we need from the CLI's video-info JSON line.
private struct VideoInfoEnvelope: Decodable {
  var data: DataEnvelope

  struct DataEnvelope: Decodable {
    var video: VideoEnvelope
  }

  struct VideoEnvelope: Decodable {
    var title: String
    var createdAt: Date
    var lengthSeconds: Int
    var owner: OwnerEnvelope
    /// Processing VODs may omit previews; their absence must not fail metadata decoding.
    var thumbnailURLs: [String]?
  }

  struct OwnerEnvelope: Decodable {
    var displayName: String
    /// Missing login must not discard the video's other metadata.
    var login: String?
  }
}

/// Fields from upstream's `GqlShareClipRenderStatusResponse`. Assets are optional because raw
/// info uses `canThrow: false` and may return deleted/unpublished clips without them. Core
/// naming fields remain required.
private struct ClipInfoEnvelope: Decodable {
  var data: DataEnvelope

  struct DataEnvelope: Decodable {
    var clip: ClipEnvelope
  }

  struct ClipEnvelope: Decodable {
    var title: String
    var createdAt: Date
    var durationSeconds: Int
    var broadcaster: BroadcasterEnvelope
    var assets: [AssetEnvelope]?
    /// Decode only the parent video's presence; its internal fields are irrelevant to chat
    /// availability.
    var video: ParentVideoEnvelope?
    /// Clip start within its parent broadcast. Decode separately because upstream checks both
    /// this and the parent video.
    var videoOffsetSeconds: Int?
  }

  struct ParentVideoEnvelope: Decodable {}

  struct BroadcasterEnvelope: Decodable {
    var displayName: String
    /// Missing login must not discard the clip's other metadata.
    var login: String?
  }

  struct AssetEnvelope: Decodable {
    var aspectRatio: Double?
    var thumbnailURL: String?
    var videoQualities: [ClipQualityEnvelope]?
    /// Decoded only for its presence — upstream treats a non-null
    /// `portraitMetadata` as the primary signal that an asset is vertical, and
    /// none of the crop coordinates inside it mean anything to us.
    var portraitMetadata: PortraitMetadataEnvelope?

    /// Upstream's `IsPortrait`, in order: the metadata block, then the aspect
    /// ratio, then the CDN path. All three because Twitch does not populate
    /// them consistently across clip ages.
    var isPortrait: Bool {
      if portraitMetadata != nil { return true }
      if let aspectRatio, aspectRatio > 0, aspectRatio < 1 { return true }
      return thumbnailURL?.lowercased().contains("/portrait/") ?? false
    }
  }

  struct PortraitMetadataEnvelope: Decodable {}

  struct ClipQualityEnvelope: Decodable {
    /// Height as a string (e.g. `1080`). Nil skips one unnameable rendition without failing the
    /// clip.
    var quality: String?
    var frameRate: Double
    var bitrate: Int
    var width: Int
    var height: Int
  }
}

extension Duration {
  /// This `Duration` expressed as a floating-point number of seconds.
  var asSeconds: Double {
    Double(components.seconds) + Double(components.attoseconds) * 1e-18
  }
}
