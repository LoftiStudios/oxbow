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

  /// The rendition's dimensions as Twitch reported them, or nil when it
  /// reported none — which older clips genuinely do.
  ///
  /// The one parser for `resolution`. `CompositeGeometry` reads it rather than
  /// splitting the string a second time, because two parsers for one field is
  /// how two answers to one question start disagreeing.
  public var pixelSize: (width: Int, height: Int)? {
    let parts = resolution.split(separator: "x")
    guard parts.count == 2,
          let width = Int(parts[0]), let height = Int(parts[1]),
          width > 0, height > 0
    else { return nil }
    return (width, height)
  }

  /// The smaller dimension — the orientation-agnostic reading of the `p`
  /// number in the name.
  ///
  /// `1080p60-Portrait` is 1080x1920: its height is 1920 and its `1080p` is
  /// the **width**. Anything comparing a rendition against a quality ceiling
  /// has to read this, or a portrait clip files as the highest tier there is.
  public var shortSide: Int? {
    guard let size = pixelSize else { return nil }
    return min(size.width, size.height)
  }

  /// The value to pass as the CLI's `-q`, as distinct from `name`.
  ///
  /// Upstream's `ClipVideoQualities.GetQuality` resolves `-q` by an **exact
  /// name match** first, only falling back to keywords and a
  /// `WIDTHxHEIGHTpFPS` regex when that fails — and that fallback can
  /// silently resolve to the wrong rendition. So the only reliable value to
  /// send is a name upstream would itself produce, which is not always
  /// `name`: `clipQualities` disambiguates repeats **across the whole list**,
  /// while upstream disambiguates **per asset**, so the two can diverge.
  ///
  /// **Measured against the real bundled helper (1.56.5)** on a clip whose
  /// renditions include 1080p60, 720p60 and 480p30: a `-<digits>` suffix
  /// `clipQualities` invented purely to break a list-wide tie (`480p30-1`,
  /// `480p30-2`, `720p60-1` — none of these exist as upstream names) does not
  /// resolve as `-q` at all. It fails silently — exit code 0, no warning —
  /// and falls back to the highest rendition:
  ///
  /// | `-q` argument | resolution actually downloaded |
  /// |---|---|
  /// | `480p30-1` | 1920x1080 (wrong) |
  /// | `480p30-2` | 1920x1080 (wrong) |
  /// | `720p60-1` | 1920x1080 (wrong) |
  /// | `480p30`   | 852x480 (correct) |
  /// | `720p60`   | 1280x720 (correct) |
  /// | `480p`     | 852x480 (correct) |
  ///
  /// Stripping a suffix like that — one we invented — is what makes it
  /// resolve. But a `-Portrait-<digits>` name is the opposite case: there,
  /// upstream's own per-asset disambiguation is what produced the `-N`, and
  /// the full name is the one that resolves correctly:
  ///
  /// | `-q` argument | resolution actually downloaded |
  /// |---|---|
  /// | `1080p60-Portrait-1` | 1080x1920 (correct, portrait) |
  /// | `1080p60-Portrait`   | 1920x1080 (wrong — same file as `1080p60-1`) |
  ///
  /// Stripping *that* `-1` would hand someone the landscape file and call it
  /// a success. So the rule cannot be "strip any trailing `-<digits>`" — it
  /// has to strip one **only when what remains is a bare quality name**,
  /// i.e. the remainder matches `^\d{3,4}p\d{1,3}$`. A `-Portrait` name never
  /// matches that (the remainder still has `-Portrait` on it), so it is never
  /// stripped, whether or not it carries its own upstream `-N`.
  ///
  /// **The trap this must not fall into: a trailing digit is not always a
  /// disambiguation suffix.** `720p0` is one token — `0` is the framerate,
  /// upstream's placeholder for a clip with no framerate metadata — and
  /// stripping it would turn `720p0` into `720p`, a different (and possibly
  /// nonexistent) rendition. Only a *hyphen* followed by digits at the end,
  /// with a bare quality name left over, counts.
  ///
  /// `name` itself is untouched by this: it stays upstream-verbatim because
  /// it is what the picker displays and what disambiguates two renditions
  /// that would otherwise collide.
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
  /// The video's own preview image, for the intake sheet to show.
  ///
  /// Optional because Twitch does not always have one: a VOD still processing
  /// arrives with an empty `thumbnailURLs`, and a clip whose assets are
  /// missing has no preview either. Both are states the sheet already handles
  /// for the rest of the metadata, so this is one more thing that may be
  /// absent rather than a reason to fail the parse.
  ///
  /// **The two shapes give us different sizes.** A VOD's is 320x180 — the CLI
  /// hardcodes `thumbnailURLs(height:180,width:320)` in its GraphQL query, so
  /// there is no larger one to ask for. A clip's is the asset's full-size
  /// preview, 1920x1080 on a modern clip. The smaller of the two is what caps
  /// how large the sheet may draw it.
  public var thumbnailURL: URL?

  /// Whether this video's chat can be downloaded at all.
  ///
  /// False only for a clip whose parent broadcast is gone. A clip carries no
  /// chat of its own — upstream reconstructs it from the VOD the clip was cut
  /// from, seeking to `videoOffsetSeconds` — so when Twitch has expired or
  /// deleted that broadcast there is nothing to read, and
  /// `ChatDownloader.InitChatRoot` aborts the process with "Invalid VOD for
  /// clip, deleted/expired VOD possibly?".
  ///
  /// **This is upstream's own predicate, not a proxy for it.** The `info`
  /// verb and the chat downloader both call
  /// `TwitchHelper.GetShareClipRenderStatus`, so we test
  /// `clip.video == null || clip.videoOffsetSeconds == null` over the same
  /// document `ChatDownloader` will test — which is what keeps this clear of
  /// docs/twitch-metadata.md §6, where the sin is trusting a field that
  /// merely correlates with what you want to know.
  ///
  /// **It is still a hint about the future, and only safe in one direction.**
  /// An expired broadcast never comes back, so false stays false and refusing
  /// on it is sound. True can go stale — §5 of that document shows a clip
  /// payload changing inside half an hour — so a VOD can expire between
  /// intake and the job actually running. `FailureInterpreter` therefore
  /// keeps its own case for this; nothing here replaces it.
  ///
  /// True for every VOD: a VOD *is* the broadcast, so it has no parent that
  /// could have expired. Defaulted true in `init` for the same reason every
  /// other caller — tests, previews — is describing something whose chat is
  /// fine.
  public var hasDownloadableChat: Bool

  /// `thumbnailURL` defaults to nil: it adorns the intake sheet and nothing
  /// else derives from it, so the tests and previews that build a `VideoInfo`
  /// for its name, duration or qualities should not have to name one.
  public init(
    streamer: String,
    title: String,
    createdAt: Date,
    duration: Duration,
    qualities: [StreamQuality],
    thumbnailURL: URL? = nil,
    hasDownloadableChat: Bool = true)
  {
    self.streamer = streamer
    self.title = title
    self.createdAt = createdAt
    self.duration = duration
    self.qualities = qualities
    self.thumbnailURL = thumbnailURL
    self.hasDownloadableChat = hasDownloadableChat
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
        qualities: Self.parseQualities(from: lines[(jsonLineIndex + 1)...]),
        // One URL per preview frame, in order. The first is the one upstream's
        // own WPF pages show (`PageVodDownload.xaml.cs`), so it is the one a
        // person recognises as "that VOD's thumbnail".
        thumbnailURL: video.thumbnailURLs?.first.flatMap(URL.init(string:)))
    }

    if let envelope = try? decoder.decode(ClipInfoEnvelope.self, from: jsonData) {
      let clip = envelope.data.clip
      return VideoInfo(
        streamer: clip.broadcaster.displayName,
        title: clip.title,
        createdAt: clip.createdAt,
        duration: .seconds(clip.durationSeconds),
        qualities: Self.clipQualities(of: clip),
        thumbnailURL: Self.clipThumbnailURL(of: clip),
        // Upstream's exact condition, negated. Both fields, not just
        // `video`: upstream checks both, and a payload carrying one without
        // the other would abort the chat download just the same.
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

  /// The clip's renditions, named exactly as upstream names them.
  ///
  /// **The names have to match upstream's, character for character**, because
  /// the name (via `StreamQuality.commandLineValue`, see its doc for the
  /// exact rule) is what the picker later hands back as `-q`. Upstream's
  /// `ClipVideoQualities.GetQuality` tries an exact-name match first and only
  /// then falls back to keywords and a `WIDTHxHEIGHTpFPS` regex, which cannot
  /// parse a `-Portrait` name at all.
  ///
  /// That fallback does not fail loudly. Verified against the real CLI:
  /// `-q 1080p60-Portrait-1` downloads the portrait rendition, and the
  /// tidier-looking `-q 1080p60-Portrait` downloads the **landscape** one —
  /// byte-for-byte the same file as `-q 1080p60-1`, exit code 0, no warning.
  /// A prettier name of our own invention would therefore hand people the
  /// wrong video and call it a success. So this reproduces
  /// `VideoQualities.FromClip` / `BuildQualityList`:
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

  /// The clip's preview image: the first landscape asset's, falling back to
  /// the first asset that has one at all.
  ///
  /// Landscape first for the same reason `clipQualities` sorts it first — a
  /// clip commonly carries both a landscape and a portrait asset, and the
  /// landscape one is the clip as it was streamed. The fallback is what makes
  /// a genuinely vertical clip (which has no landscape asset) show a preview
  /// rather than nothing.
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
    /// Optional, and optional for a reason: a VOD that is still processing
    /// comes back without previews. Making it required would fail the whole
    /// parse over a decoration and drop the sheet back to naming the job
    /// after a bare id.
    var thumbnailURLs: [String]?
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
    /// The broadcast this clip was cut from, decoded **only for its
    /// presence** — the same idiom as `portraitMetadata` below, and for the
    /// same reason: an empty `Decodable` accepts any object shape, so a
    /// future field appearing inside `video` can never fail the whole clip's
    /// metadata over something we do not read. Its `id` is upstream's
    /// business, not ours.
    var video: ParentVideoEnvelope?
    /// Where in that broadcast the clip starts. Null exactly when `video` is,
    /// in every payload observed — but upstream tests both, so we decode
    /// both rather than assume they move together.
    var videoOffsetSeconds: Int?
  }

  struct ParentVideoEnvelope: Decodable {}

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
