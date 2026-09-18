import Foundation

/// Sizes the chat column and composite from rendition metadata without probing the file.
public struct CompositeGeometry: Sendable, Equatable {
  public var videoWidth: Int
  public var videoHeight: Int
  public var chatWidth: Int
  public var videoFramerate: Int
  /// The chat's own render rate, always the video's divided by a small
  /// integer. `ArgumentBuilder` normalises it back up before stacking.
  public var chatFramerate: Int

  public var outputWidth: Int { videoWidth + chatWidth }

  /// Composite pixels per second: video plus chat width, at the video's frame rate. Uses the
  /// same denominator as the measurements in `docs/design/composite-rate-control.md` §4.2 so
  /// `SpaceEstimate` can reuse their bits-per-pixel estimate.
  public var pixelRate: Double {
    Double(outputWidth) * Double(videoHeight) * Double(videoFramerate)
  }

  /// The narrowest legible chat column.
  static let minimumChatWidth = 160

  /// Returns nil when metadata has no usable dimensions; chat height cannot be inferred safely.
  public init?(quality: StreamQuality) {
    guard let size = quality.pixelSize else { return nil }
    let rawWidth = size.width
    let rawHeight = size.height

    // Round metadata dimensions down to even before sizing chat. Twitch's clip API reports
    // 480x853 for a stream that decodes at 480x852; using 853 makes `hstack` fail because the
    // input heights differ.
    let width = rawWidth - (rawWidth % 2)
    let height = rawHeight - (rawHeight % 2)
    guard width > 0, height > 0 else { return nil }

    self.videoWidth = width
    self.videoHeight = height
    self.videoFramerate = Self.framerate(fromName: quality.name)

    // Use 3/16 of video width (1920 → 360, 1280 → 240), rounded down to even. VideoToolbox
    // silently crops odd output widths, and even video widths can produce odd chat widths (852
    // × 3/16 = 159).
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



  // MARK: - Chat font size

  /// Medium is chatWidth / 22.5, calibrated on a 360x1080 chat render; see
  /// docs/design/compositing.md §4.
  private static let mediumDivisor = 22.5
  private static let smallMultiplier = 0.8
  private static let mediumMultiplier = 1.0
  private static let largeMultiplier = 1.25

  /// Scale font size with column width, round to whole points, and clamp to at least 1.
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

  /// Read fps digits after p, allowing rendition suffixes. Never use m3u8 FRAME-RATE: its
  /// measured average can differ from the nominal video rate (docs/architecture.md §7).
  private static func framerate(fromName name: String) -> Int {
    guard let match = name.firstMatch(of: /p(\d+)/),
          let parsed = Int(match.1),
          parsed > 0
    else { return 30 }
    return parsed
  }
}
