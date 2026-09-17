import CoreGraphics
import Foundation

/// Tile-relative geometry; badge measurements match the system badge. See docs/design/status.md
/// §5.2.
nonisolated struct DockTileMetrics: Equatable {

  // MARK: Measured from the platform

  /// Measured system badge diameter: 50/128 of the tile, tangent to its top and right edges.
  let badgeDiameter: Double

  // MARK: Chosen by us

  /// Place the bar inside the icon artwork, which occupies roughly 0.13...0.87 of the padded
  /// tile.
  let barWidth: Double
  let barHeight: Double
  let barBottomInset: Double

  static let standard = DockTileMetrics(
    badgeDiameter: 50.0 / 128,
    barWidth: 0.48,
    barHeight: 0.052,
    barBottomInset: 0.20)

  struct Resolved: Equatable {
    let iconRect: CGRect
    let badgeRect: CGRect
    let barRect: CGRect
    let barCornerRadius: CGFloat
  }

  /// Draw applicationIconImage edge-to-edge: it already includes system padding. The badge
  /// overlaps its corner like the platform badge.
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
