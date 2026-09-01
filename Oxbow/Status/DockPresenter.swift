import AppKit
import OxbowKit

/// Puts the queue's state on the dock tile, and takes it off again.
///
/// **The content view is installed only while there is something to draw.**
/// At rest the tile is handed back to the system, which owns the icon
/// completely — so the question `docs/design/status.md` §2.4 left open (is the
/// tile told when the user changes icon appearance?) never has to be answered.
/// While working we redraw several times a second anyway, so a change is
/// picked up within a frame either way.
///
/// Do not "simplify" this by installing the content view once at launch.
@MainActor
final class DockPresenter {

  private let metrics: DockTileMetrics
  private var view: DockTileView?
  private var current: QueueStatus?

  init(metrics: DockTileMetrics = .standard) {
    self.metrics = metrics
  }

  func apply(_ jobs: [Job]) {
    let tile = NSApp.dockTile
    let status = QueueStatus(jobs: jobs, quantum: quantum)

    // Quantized, so a render's ~400 snapshots collapse to at most one redraw
    // per drawable pixel of bar. Spec §6.
    guard status != current else { return }
    current = status

    guard !status.isIdle else {
      view = nil
      tile.contentView = nil
      tile.display()
      return
    }

    let tileView = view ?? {
      let made = DockTileView(metrics: metrics)
      view = made
      return made
    }()

    if tile.contentView !== tileView { tile.contentView = tileView }
    tileView.status = status
    tile.display()
  }

  /// One quantum per drawable pixel of bar.
  ///
  /// Constant, not read from `NSApp.dockTile.size`, because that size is
  /// always 128x128 whatever the user's Dock size preference — the system
  /// scales the rendered tile rather than handing us a smaller one (§5.2). A
  /// small Dock therefore has *fewer* real pixels than this assumes, so the
  /// quantum is conservative: it can only cause redraws that are invisible,
  /// never skip one that would have shown.
  private var quantum: Double { 1 / (128 * metrics.barWidth) }
}
