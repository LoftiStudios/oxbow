import AppKit

/// Draws a `QueueStatus` onto the dock tile.
///
/// **Setting `NSDockTile.contentView` replaces the icon**, so this view is
/// responsible for drawing the icon too. `NSApp.applicationIconImage` returns
/// the appearance-treated rendering — verified, see `docs/design/status.md`
/// §2 — so Clear and Tinted survive being drawn by us. Do not substitute a
/// bundled asset here; that is exactly the mistake §2.2 attributes to
/// Transmission, and it is what makes its dock icon ignore the user's icon
/// appearance setting while its Finder icon honours it.
///
/// **Never set `badgeLabel` while this view is installed.** The system draws
/// that badge on top of the content view rather than instead of it, so the
/// two would stack.
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

    // A dark rim under the track. The icon behind it is whatever appearance
    // the user has chosen — up to and including Clear, which is translucent —
    // so the track cannot rely on contrasting with a known background.
    NSColor.black.withAlphaComponent(0.35).setFill()
    track.fill()

    NSColor.white.withAlphaComponent(0.9).setFill()
    track.fill()

    // `.indeterminate` is the track alone: working, no estimate. An absent
    // bar would read as idle, which is a lie while a chat download runs.
    guard case .fraction(let value) = bar, value > 0 else { return }

    var filled = layout.barRect
    filled.size.width *= value
    // Below one corner diameter a rounded rect degenerates into a lens; a
    // plain rect reads better at the very start of a job.
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

  /// Cap height as a fraction of the badge's diameter, measured from the
  /// platform's own badge: an `8` stood 16px tall in a 46px disc (§5.2).
  /// Divided by SF's cap-height ratio to get a point size.
  private static let badgeCapHeightRatio = 0.348
  private static let capHeightOfSystemFont = 0.72

  private func draw(badge: QueueStatus.Badge?, in layout: DockTileMetrics.Resolved) {
    guard let badge else { return }

    let (background, foreground, text): (NSColor, NSColor, String) = switch badge {
    case .count(let n): (.white, .black, "\(n)")
    case .alert: (.systemRed, .white, "!")
    }

    // A hairline ring, so a white badge still reads as a badge against a pale
    // icon and a red one still reads against a dark Dock.
    let circle = NSBezierPath(ovalIn: layout.badgeRect.insetBy(dx: 1, dy: 1))
    background.setFill()
    circle.fill()
    NSColor.black.withAlphaComponent(0.18).setStroke()
    circle.lineWidth = max(1, layout.badgeRect.width * 0.03)
    circle.stroke()

    let size = layout.badgeRect.width
      * Self.badgeCapHeightRatio / Self.capHeightOfSystemFont
    let string = NSAttributedString(string: text, attributes: [
      .font: NSFont.systemFont(ofSize: size, weight: .semibold),
      .foregroundColor: foreground])

    // Centre on the cap height rather than the line box: a line box carries
    // descender space the glyphs here never use ("8" and "!" have none), so
    // centring on it sits the text visibly high in the disc.
    let measured = string.size()
    let font = NSFont.systemFont(ofSize: size, weight: .semibold)
    string.draw(at: NSPoint(
      x: layout.badgeRect.midX - measured.width / 2,
      y: layout.badgeRect.midY - font.capHeight / 2 + font.descender))
  }
}
