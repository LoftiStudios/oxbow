import AppKit

/// A custom contentView replaces the icon, so redraw NSApp.applicationIconImage to retain
/// system appearance treatment. Do not also set badgeLabel: the system would overlay a second
/// badge.
@MainActor
final class DockTileView: NSView {

  var status: QueueStatus = QueueStatus(jobs: [], quantum: 0) {
    didSet {
      guard status != oldValue else { return }
      needsDisplay = true
    }
  }

  private let metrics: DockTileMetrics

  init(metrics: DockTileMetrics = .standard) {
    self.metrics = metrics
    // `NSApp.dockTile.size` is a fixed 128x128 whatever the user's Dock size
    // preference; the system scales the result down. See §5.2.
    super.init(frame: NSRect(x: 0, y: 0, width: 128, height: 128))
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("not used") }

  override func draw(_ dirtyRect: NSRect) {
    let layout = metrics.resolved(forTileWidth: bounds.width)

    NSApp.applicationIconImage?.draw(
      in: layout.iconRect,
      from: .zero,
      operation: .sourceOver,
      fraction: 1)

    draw(bar: status.bar, in: layout)
    draw(badge: status.badge, in: layout)
  }

  // MARK: - Bar

  private func draw(bar: QueueStatus.Bar, in layout: DockTileMetrics.Resolved) {
    guard bar != .hidden else { return }

    let track = NSBezierPath(
      roundedRect: layout.barRect,
      xRadius: layout.barCornerRadius,
      yRadius: layout.barCornerRadius)

    // A dark rim separates the track from arbitrary icon appearances, including Clear.
    NSColor.black.withAlphaComponent(0.35).setFill()
    track.fill()

    NSColor.white.withAlphaComponent(0.9).setFill()
    track.fill()

    // Indeterminate work shows the track alone; omitting it would imply idle.
    guard case .fraction(let value) = bar, value > 0 else { return }

    var filled = layout.barRect
    filled.size.width *= value
    // Use a rectangle below one corner diameter to avoid a lens-shaped fill.
    let fill = filled.width >= layout.barCornerRadius * 2
      ? NSBezierPath(
          roundedRect: filled,
          xRadius: layout.barCornerRadius,
          yRadius: layout.barCornerRadius)
      : NSBezierPath(rect: filled)

    Brand.dockProgress.setFill()
    fill.fill()
  }

  // MARK: - Badge

  /// Measured badge cap-height ratio: 16px in a 46px disc. Convert through the font's
  /// cap-height ratio to get point size.
  private static let badgeCapHeightRatio = 0.348
  private static let capHeightOfSystemFont = 0.72

  private func draw(badge: QueueStatus.Badge?, in layout: DockTileMetrics.Resolved) {
    guard let badge else { return }

    // Use the queue's warning triangle for failure, distinct in shape from a count badge.
    guard case .count(let n) = badge else {
      drawAlert(in: layout.badgeRect)
      return
    }
    // A rim keeps a white badge visible on pale icon appearances.
    let circle = NSBezierPath(ovalIn: layout.badgeRect.insetBy(dx: 1, dy: 1))
    NSColor.white.setFill()
    circle.fill()
    NSColor.black.withAlphaComponent(0.18).setStroke()
    circle.lineWidth = max(1, layout.badgeRect.width * 0.03)
    circle.stroke()

    let size = layout.badgeRect.width
      * Self.badgeCapHeightRatio / Self.capHeightOfSystemFont
    let font = NSFont.systemFont(ofSize: size, weight: .semibold)
    let string = NSAttributedString(string: "\(n)", attributes: [
      .font: font,
      .foregroundColor: NSColor.black])

    // Centre digits by cap height, excluding unused descender space.
    let measured = string.size()
    string.draw(at: NSPoint(
      x: layout.badgeRect.midX - measured.width / 2,
      y: layout.badgeRect.midY - font.capHeight / 2 + font.descender))
  }

  /// Palette order is [mark, triangle]: white, then red. Inset the triangle to avoid clipping
  /// at the tile edge.
  private func drawAlert(in rect: CGRect) {
    let box = rect
      .insetBy(dx: rect.width * 0.04, dy: rect.height * 0.04)
      .offsetBy(dx: -rect.width * 0.04, dy: -rect.height * 0.04)
    let configuration = NSImage.SymbolConfiguration(paletteColors: [.white, .systemRed])
      .applying(NSImage.SymbolConfiguration(pointSize: box.width, weight: .semibold))
    guard let image = NSImage(
      systemSymbolName: "exclamationmark.triangle.fill",
      accessibilityDescription: "failed")?.withSymbolConfiguration(configuration)
    else { return }

    let scale = min(box.width / image.size.width, box.height / image.size.height)
    let drawn = NSSize(width: image.size.width * scale, height: image.size.height * scale)
    image.draw(in: NSRect(
      x: box.midX - drawn.width / 2,
      y: box.midY - drawn.height / 2,
      width: drawn.width,
      height: drawn.height))
  }
}
