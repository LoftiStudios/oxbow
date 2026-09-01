import CoreGraphics
import Foundation

/// Dock tile geometry, as ratios of the tile's width.
///
/// The badge number is **measured from the platform's own `badgeLabel`**, not
/// chosen — see `docs/design/status.md` §5.2 for the method and the numbers.
/// Geometry is what makes a badge read as native; colour is where our meaning
/// lives, and colour is the only axis on which we deliberately diverge.
///
/// Ratios rather than points because a tile's *displayed* size follows the
/// user's Dock size preference. The drawing space does not — see
/// `resolved(forTileWidth:)`.
nonisolated struct DockTileMetrics: Equatable {

  // MARK: Measured from the platform

  /// The system badge is a circle that exactly fills the tile's top-right
  /// corner: measured at 46px across in a 118px tile, with its centre 24.4pt
  /// from the top edge and 24.4pt from the right — one radius from each, to
  /// within half a point. So the badge is tangent to both edges, and this one
  /// number describes it completely.
  ///
  /// 0.3906 is 50/128 — the measurement lands on a round number of points in
  /// the tile's own 128pt space, which is a good sign it is the real value
  /// rather than an artefact of the capture.
  let badgeDiameter: Double

  // MARK: Chosen by us

  let barWidth: Double
  let barHeight: Double
  let barBottomInset: Double

  static let standard = DockTileMetrics(
    badgeDiameter: 50.0 / 128,
    barWidth: 0.62,
    barHeight: 0.055,
    barBottomInset: 0.13)

  struct Resolved: Equatable {
    let iconRect: CGRect
    let badgeRect: CGRect
    let barRect: CGRect
    let barCornerRadius: CGFloat
  }

  /// Points, for a square tile of the given width.
  ///
  /// **The icon is drawn into the full bounds, with no inset.** That is not an
  /// oversight: `NSApp.applicationIconImage` carries its own padding, so
  /// drawing it edge-to-edge reproduces the system's placement exactly. It was
  /// verified rather than assumed — with the content view outlining its own
  /// bounds, our icon body and the system's landed on identical columns
  /// (`438...507` in a tile spanning `414...531`). An earlier note in the
  /// design doc claimed we drew slightly too large; that was an artefact of
  /// comparing crops from two captures, and is retracted in §2.3.
  ///
  /// The badge therefore overlaps the icon's corner, exactly as the
  /// platform's own badge does on every app in the Dock.
  func resolved(forTileWidth width: CGFloat) -> Resolved {
    let diameter = width * badgeDiameter
    // The top-right corner square. `NSView` is not flipped, so y grows upward.
    let badge = CGRect(
      x: width - diameter,
      y: width - diameter,
      width: diameter,
      height: diameter)

    let barW = width * barWidth
    let barH = width * barHeight
    let bar = CGRect(
      x: (width - barW) / 2,
      y: width * barBottomInset,
      width: barW,
      height: barH)

    return Resolved(
      iconRect: CGRect(x: 0, y: 0, width: width, height: width),
      badgeRect: badge,
      barRect: bar,
      barCornerRadius: barH / 2)
  }
}
