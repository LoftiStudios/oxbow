import Foundation

/// One downloadable rendition from the VOD's m3u8 master playlist.
public struct StreamQuality: Sendable, Equatable {
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
}

/// The video's own metadata plus its available qualities, as parsed from the
/// CLI's `info --format Raw` output.
///
/// `--format Raw` because `--format json` throws `NotImplementedException`
/// upstream (worth a PR there).
///
/// **Two payload shapes, not one.** `InfoHandler` branches on whether the id
/// is all digits, and the two branches emit completely different documents:
///
/// - A **VOD** (`HandleVodRaw`) writes three parts on stdout: a line of
///   video-info JSON (`{"data":{"video":…}}`), a line of "moments" JSON, then
///   an m3u8 master playlist. Qualities come from that playlist.
/// - A **clip** (`HandleClipRaw`) writes one JSON object and nothing else:
///   `{"data":{"clip":…}}`, whose qualities live inline at
///   `clip.assets[].videoQualities`. There is no m3u8 section at all.
///
/// So parsing means finding the first line that is JSON, trying each envelope
/// in turn, and taking qualities from wherever that shape keeps them. Both
/// produce the same `VideoInfo`, so nothing downstream has to know which link
/// the user pasted.
public struct VideoInfo: Sendable, Equatable {
  public var streamer: String
  public var title: String
  public var createdAt: Date
  public var duration: Duration
  public var qualities: [StreamQuality]

  public init(
    streamer: String,
    title: String,
    createdAt: Date,
    duration: Duration,
    qualities: [StreamQuality])
  {
    self.streamer = streamer
    self.title = title
    self.createdAt = createdAt
    self.duration = duration
    self.qualities = qualities
  }

  public static func parse(_ output: String) -> VideoInfo? {
    let lines = output.split(separator: "\n", omittingEmptySubsequences: false)

    guard let jsonLineIndex = lines.firstIndex(where: isJSONObjectLine),
          let jsonData = lines[jsonLineIndex].data(using: .utf8)
    else { return nil }

    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601

    // VOD first, clip second. The two envelopes cannot both decode the same
    // payload — a VOD's `data` has no `clip` key and a clip's has no `video`
    // key — so the order is only about which failure is the common one, not
    // about resolving an ambiguity.
    if let envelope = try? decoder.decode(VideoInfoEnvelope.self, from: jsonData) {
      let video = envelope.data.video
      return VideoInfo(
        streamer: video.owner.displayName,
        title: video.title,
        createdAt: video.createdAt,
        duration: .seconds(video.lengthSeconds),
        // The m3u8 master playlist follows the JSON lines, and only for a VOD.
        qualities: Self.parseQualities(from: lines[(jsonLineIndex + 1)...]))
    }

    if let envelope = try? decoder.decode(ClipInfoEnvelope.self, from: jsonData) {
      let clip = envelope.data.clip
      return VideoInfo(
        streamer: clip.broadcaster.displayName,
        title: clip.title,
        createdAt: clip.createdAt,
        duration: .seconds(clip.durationSeconds),
        qualities: Self.clipQualities(of: clip))
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

  /// The clip's renditions, named exactly as upstream names them.
  ///
  /// **The names have to match upstream's, character for character**, because
  /// the name is what the picker later hands back as `-q`. Upstream's
  /// `ClipVideoQualities.GetQuality` tries an exact-name match first and only
  /// then falls back to keywords and a `WIDTHxHEIGHTpFPS` regex — and that
  /// regex cannot parse a `-Portrait` name at all, so a prettier name of our
  /// own invention would leave every vertical rendition unselectable. So this
  /// reproduces `VideoQualities.FromClip` / `BuildQualityList`:
  ///
  /// - `{quality}p{frameRate rounded}`, with `-Portrait` appended for a
  ///   vertical asset;
  /// - repeated names disambiguated `-1`, `-2`, … (Twitch really does return
  ///   each rendition twice);
  /// - landscape before portrait, then by descending height, framerate, name.
  ///
  /// The one deliberate divergence is that byte-identical renditions are
  /// collapsed. Twitch returns every rendition twice, so a faithful list is
  /// half duplicate rows in the picker; the survivor keeps the `-1` name
  /// upstream gave it, so it still matches exactly. Two renditions that share
  /// a name but differ in size or bitrate are both kept.
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

  /// Splits an `EXT-X-STREAM-INF` attribute list on top-level commas only.
  ///
  /// `CODECS="avc1.640029,mp4a.40.2"` contains a comma *inside* its quoted
  /// value. A plain `split(separator: ",")` would break that field in two and
  /// shift every attribute after it — and it would look correct on any
  /// variant whose CODECS happens to list a single codec. So this walks the
  /// string tracking quote state and only splits where we are not inside `"`.
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
  }

  struct OwnerEnvelope: Decodable {
    var displayName: String
  }
}

/// Mirrors just the fields we need from the CLI's clip JSON.
///
/// Field names and nesting come from
/// `TwitchDownloaderCore/TwitchObjects/Gql/GqlShareClipRenderStatusResponse.cs`,
/// which `InfoHandler.HandleClipRaw` serializes verbatim.
///
/// `assets` and its members are optional because `--format Raw` is the one
/// path upstream fetches with `canThrow: false` — a deleted or unpublished
/// clip reaches us with its assets missing rather than as an error. `title`,
/// `createdAt`, `durationSeconds` and `broadcaster` are not: a payload without
/// them is not a clip we can name a file after, and failing the decode there
/// is what puts the sheet into its (honest) "could not read that video's
/// details" state instead of silently naming a job after nobody.
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
  }

  struct BroadcasterEnvelope: Decodable {
    var displayName: String
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
    /// The frame height as a string — `"1080"`, not `"1080p60"`. Optional
    /// only so that one unnameable rendition is skipped rather than failing
    /// the whole clip's metadata; upstream declares it nullable too.
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
