import AppKit
import OxbowKit

/// Install a custom Dock content view only while active; return the idle icon to the system.
/// Active redraws pick up appearance changes.
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

    // Quantization limits redraws to meaningful bar-pixel changes.
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

  /// NSDockTile draws at 128pt regardless of displayed size. One quantum per drawable bar pixel
  /// is conservative when the Dock scales it down.
  private var quantum: Double { 1 / (128 * metrics.barWidth) }
}
