import Foundation

/// How much room a job will need, in bytes, from what the intake already knows.
///
/// **Read `docs/design/disk-preflight.md` §3 before changing any constant
/// here.** The short version: three of these terms are solid and the fourth is
/// a median of four samples spanning 5.3x, so this is an order of magnitude
/// rather than a number. It exists to catch a job that is obviously too big,
/// not to promise that one will fit — §9 of that document is explicit that a
/// passing preflight is not a guarantee, and anything built on top of this
/// should read it that way too.
///
/// Pure arithmetic: no file system, no network, no probe. That is what lets the
/// intake recompute it on every keystroke, and it is why the volume read lives
/// in `VolumeSpace` instead of here.
public struct SpaceEstimate: Sendable, Equatable {

  /// Bits per composite output pixel — the median of the four `-q:v 50`
  /// measurements in `composite-rate-control.md` §2 (0.022, 0.023, 0.053,
  /// 0.119).
  ///
  /// Scaled by pixel rate rather than used as a flat megabit figure because
  /// §4.2's own cross-geometry table shows a flat rate over-states smaller
  /// geometries by 63% where this is wrong by at most a fifth. That is not a
  /// contradiction of that section's "no bpp constant could have worked" —
  /// that verdict is about bits-per-pixel as an *encoder input* held to within
  /// a decibel of a quality target, which is a far stricter bar than a size
  /// estimate whose content term already spans 5.3x. See `disk-preflight.md`
  /// §3.1.
  public static let compositeBitsPerPixel = 0.038

  /// The chat render intermediate, measured in practice — text on a flat
  /// background compresses far below its 12 Mbps ceiling.
  ///
  /// Deliberately flat across geometries where `composite` scales with them.
  /// `disk-preflight.md` §3 explains why: this is a single figure at 1080p,
  /// scaling it would mean inventing a bits-per-pixel for the chat column that
  /// nobody has measured, and it is the smallest of the three terms. Flat
  /// over-states smaller geometries, which errs toward warning.
  public static let chatRenderBitsPerSecond = 3_850_000.0

  /// The downloaded source. The most trustworthy term by a wide margin: Twitch
  /// transcodes to a flat target, and delivered bitrate measures 95–97% of
  /// advertised across every sample in `composite-quality.md` §4.1.
  public var source: Int64

  /// The chat render intermediate. Zero when the job renders no chat.
  public var chatRender: Int64

  /// The composited output. Zero when the job composites nothing.
  public var composite: Int64

  /// The peak on the volume holding the workspace: source, intermediate and
  /// output all coexist there while the composite is being written.
  public var total: Int64 { source + chatRender + composite }

  /// What the *destination* volume needs on its own — the one delivered file,
  /// not the transient set.
  ///
  /// Equal to `total` only for a plain download whose destination shares the
  /// workspace's volume. Keeping the two separate is what lets the check treat
  /// an external drive as its own budget rather than summing two volumes into
  /// a number describing neither.
  public var delivered: Int64 { composite > 0 ? composite : source }

  /// - Parameter geometry: the composite's geometry, or `nil` for a job that
  ///   only downloads. `nil` zeroes both the render and the composite terms,
  ///   because a plain download produces neither.
  public init(quality: StreamQuality, duration: Duration, composite geometry: CompositeGeometry?) {
    // Clamped because `Duration` is signed and the intake has two timecode
    // fields a user can cross. A negative estimate would compare as "fits"
    // against any free space at all, which is the wrong direction to be wrong
    // in for a check whose entire job is refusing to start.
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
