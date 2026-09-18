import Foundation

/// Advisory peak disk estimate from intake metadata, without I/O. Composite samples span 5.3×,
/// so passing preflight does not guarantee a fit. Read `docs/design/disk-preflight.md` §3
/// before changing constants.
public struct SpaceEstimate: Sendable, Equatable {

  /// Median composite bits per output pixel from four `-q:v 50` samples (0.022, 0.023, 0.053,
  /// 0.119). Pixel-rate scaling improves estimates across geometries; this is not an encoder
  /// target. See `docs/design/disk-preflight.md` §3.1.
  public static let compositeBitsPerPixel = 0.038

  /// Measured chat-render bitrate, below its 12 Mbps ceiling. Keep flat: only 1080p was
  /// measured, and this conservatively overestimates smaller renders.
  public static let chatRenderBitsPerSecond = 3_850_000.0

  /// Source bitrate uses Twitch's advertised bandwidth; measured files reach 95–97% of it
  /// (`composite-quality.md` §4.1).
  public var source: Int64

  /// The chat render intermediate. Zero when the job renders no chat.
  public var chatRender: Int64

  /// The composited output. Zero when the job composites nothing.
  public var composite: Int64

  /// The peak on the volume holding the workspace: source, intermediate and
  /// output all coexist there while the composite is being written.
  public var total: Int64 { source + chatRender + composite }

  /// Delivered bytes, excluding intermediates. Used separately when the destination and
  /// workspace occupy different volumes.
  public var delivered: Int64 { composite > 0 ? composite : source }

  /// - Parameter geometry: the composite's geometry, or `nil` for a job that
  ///   only downloads. `nil` zeroes both the render and the composite terms,
  ///   because a plain download produces neither.
  public init(quality: StreamQuality, duration: Duration, composite geometry: CompositeGeometry?) {
    // Crossed trim fields can produce negative duration; clamp it rather than report negative
    // space needed.
    let seconds = max(0, duration.asSeconds)

    self.source = Int64(max(0, quality.estimatedBytes(over: .seconds(seconds))))

    guard let geometry else {
      self.chatRender = 0
      self.composite = 0
      return
    }
    self.chatRender = Int64(Self.chatRenderBitsPerSecond * seconds / 8)
    self.composite = Int64(Self.compositeBitsPerPixel * geometry.pixelRate * seconds / 8)
  }
}
