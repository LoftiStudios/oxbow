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

  /// The narrowest legible chat column.
  static let minimumChatWidth = 160

  /// Fails when the quality carries no pixel width. A clip old enough to have
  /// no dimensions backfilled cannot be composited, because the chat's height
  /// must equal the video's and a guessed height produces a silently wrong
  /// frame rather than a loud failure.
  public init?(quality: StreamQuality) {
    let parts = quality.resolution.split(separator: "x")
    guard parts.count == 2,
          let width = Int(parts[0]), let height = Int(parts[1]),
          width > 0, height > 0
    else { return nil }

    self.videoWidth = width
    self.videoHeight = height
    self.videoFramerate = Self.framerate(fromName: quality.name)

    // 3/16 of the video's width, because it lands on exact even integers at
    // every standard Twitch width (1920 -> 360, 1280 -> 240, 854 -> 160).
    //
    // Forced even regardless: h264_videotoolbox does NOT reject an odd width,
    // it accepts it and silently crops a column. 1920+351 produced 2270x1080
    // with exit 0 and no warning. Verified 2026-08-25.
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
