import Foundation

/// Every dimension a composite needs, derived from the chosen quality alone.
///
/// Nothing is probed. The bundled FFmpeg is built with `--disable-ffprobe`,
/// and this exists so it never needs one: `VideoInfo` already carries the
/// resolution and the name already encodes the framerate.
public struct CompositeGeometry: Sendable, Equatable {
  public var videoWidth: Int
  public var videoHeight: Int
  public var chatWidth: Int
  public var videoFramerate: Int
  /// The chat's own render rate, always the video's divided by a small
  /// integer. `ArgumentBuilder` normalises it back up before stacking.
  public var chatFramerate: Int

  public var outputWidth: Int { videoWidth + chatWidth }

  /// Output pixels per second, over the *composite* frame rather than the
  /// source's — video plus chat column, at the video's rate.
  ///
  /// This is the denominator `SpaceEstimate` divides its measured
  /// bits-per-pixel into, and it is deliberately the same quantity as the
  /// "pixel rate" column of `docs/design/composite-rate-control.md` §4.2, so
  /// the constant fitted against that table transfers here unchanged:
  /// 2280 x 1080 x 60 = 147.7M is its first row.
  ///
  /// `Double` rather than `Int` because it is only ever a divisor or a factor
  /// in a byte estimate, and an exact integer count of pixels-per-second is a
  /// precision nothing downstream has any use for.
  public var pixelRate: Double {
    Double(outputWidth) * Double(videoHeight) * Double(videoFramerate)
  }

  /// The narrowest legible chat column.
  static let minimumChatWidth = 160

  /// Fails when the quality carries no pixel width.
  ///
  /// A clip old enough to have no dimensions backfilled cannot be
  /// composited, because the chat's height must equal the video's and a
  /// guessed height produces a silently wrong frame rather than a loud
  /// failure.
  public init?(quality: StreamQuality) {
    guard let size = quality.pixelSize else { return nil }
    let rawWidth = size.width
    let rawHeight = size.height

    // Twitch's *metadata* dimensions are not always the decoded stream's:
    // h264 4:2:0 (yuv420p/yuvj420p, what every Twitch rendition uses)
    // cannot have an odd coded width or height, so a metadata value that is
    // odd is a rounding artifact, never a real frame. Verified by
    // downloading the real `480p30-Portrait` rendition, whose clip API
    // metadata claims `480x853`: the decoded stream is `480x852`. Twitch's
    // clip API *derives* dimensions arithmetically (480 x 16/9 = 853.3,
    // rounded) rather than reporting the coded size — the same rendition
    // reads `852x480` from a VOD's m3u8 but `853x480` from the clip API.
    //
    // This matters here, specifically, because the chat render's height is
    // derived from `videoHeight` below and must equal the *decoded* video's
    // height for `hstack` to accept it (§2: a mismatch is exit 234 and a
    // 0-byte output, immediately). Deriving it from an unrounded 853 while
    // the video decodes at 852 is exactly that mismatch. Rounding every
    // metadata dimension down to even, here, before anything downstream
    // reads it, keeps the two in agreement on both axes.
    let width = rawWidth - (rawWidth % 2)
    let height = rawHeight - (rawHeight % 2)
    guard width > 0, height > 0 else { return nil }

    self.videoWidth = width
    self.videoHeight = height
    self.videoFramerate = Self.framerate(fromName: quality.name)

    // 3/16 of the video's width, because it lands on exact even integers at
    // most standard Twitch widths (1920 -> 360, 1280 -> 240).
    //
    // Forced even regardless: h264_videotoolbox does NOT reject an odd
    // width, it accepts it and silently crops a column. 1920+351 produced
    // 2270x1080 with exit 0 and no warning. Verified 2026-08-25. This still
    // matters even though `width` above is now always even: 852 x 3/16 = 159,
    // an odd result from an even input.
    let scaled = max(width * 3 / 16, Self.minimumChatWidth)
    self.chatWidth = scaled - (scaled % 2)

    // Halved above 30 so a 60 fps VOD does not pay for 60 fps of slowly
    // scrolling text. Always an integer ratio, so chat frames land evenly on
    // video frames — a non-harmonic pair judders visibly.
    self.chatFramerate =
      videoFramerate > 30 && videoFramerate.isMultiple(of: 2)
        ? videoFramerate / 2
        : videoFramerate
  }

  // MARK: - Composite bitrate

  // The composite's bitrate derivation lived here and is gone. It computed a
  // rate the encoder no longer takes: `.composite` asks `h264_videotoolbox`
  // for a quality and lets it choose the cost.
  //
  // Its constants and the measurements behind them are not lost — they are in
  // `docs/design/composite-quality.md`, which is also where the reason it had
  // to go is recorded: the requirement spans 7.5x across real content, so no
  // constant could serve it, and the source bandwidth it was keyed to turned
  // out to be anti-correlated with need.

  // MARK: - Chat font size

  /// Medium's size is `chatWidth / mediumDivisor`, everything else scales
  /// off it. Chosen by rendering real chat at 360x1080 (1080p's column) and
  /// looking at the output, not derived — see `docs/design/compositing.md`
  /// §4. Trivially adjustable: this is the one number to change if a
  /// different size reads better later.
  private static let mediumDivisor = 22.5
  private static let smallMultiplier = 0.8
  private static let mediumMultiplier = 1.0
  private static let largeMultiplier = 1.25

  /// The point size for `size` in this composite's chat column.
  ///
  /// Proportional to `chatWidth`, not fixed, so characters-per-line and the
  /// overall composition look the same at every quality: a size chosen for a
  /// 360-wide 1080p column would read as oversized or illegible if reused
  /// verbatim on a 240-wide 720p one. Rounded to the nearest whole number,
  /// and never below 1 — `chatWidth` is clamped to `minimumChatWidth` but a
  /// future change to that floor should not silently produce a font size of
  /// zero or less.
  public func fontSize(for size: ChatSize) -> Double {
    let base = Double(chatWidth) / Self.mediumDivisor
    let multiplier: Double
    switch size {
    case .small: multiplier = Self.smallMultiplier
    case .medium: multiplier = Self.mediumMultiplier
    case .large: multiplier = Self.largeMultiplier
    }
    return max(1, (base * multiplier).rounded())
  }

  /// From the quality NAME, never the m3u8's `FRAME-RATE` attribute: that
  /// reports a measured average (57.034 on a 60 fps VOD) and matching it
  /// reintroduces exactly the drift this avoids. See architecture.md §7.
  ///
  /// Names carry suffixes (`1080p60-1`, `1080p60-Portrait`), so this reads the
  /// digits after the first `p` rather than anchoring to the end.
  private static func framerate(fromName name: String) -> Int {
    guard let match = name.firstMatch(of: /p(\d+)/),
          let parsed = Int(match.1),
          parsed > 0
    else { return 30 }
    return parsed
  }
}
