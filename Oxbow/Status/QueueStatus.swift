import Foundation
import OxbowKit

/// Derive Dock state from one queue snapshot: the bar reports progress, the badge reports
/// attention or count. Independent of the main actor.
nonisolated struct QueueStatus: Equatable {

  /// Failure alert takes precedence over the count badge.
  enum Badge: Equatable {
    case count(Int)
    case alert
  }

  /// Indeterminate draws an unfilled track; hidden means no active work.
  enum Bar: Equatable {
    case hidden
    case indeterminate
    case fraction(Double)
  }

  let badge: Badge?
  let bar: Bar

  /// Return the idle icon to the system when there is nothing to draw.
  var isIdle: Bool { badge == nil && bar == .hidden }

  init(jobs: [Job], quantum: Double) {
    badge = Self.badge(for: jobs)
    bar = Self.bar(for: jobs, quantum: quantum)
  }

  private static func badge(for jobs: [Job]) -> Badge? {
    if jobs.contains(where: { $0.status == .failed }) { return .alert }

    let outstanding = jobs.count { $0.status == .queued || $0.status == .running }
    // A single outstanding job needs no count badge beside its progress bar.
    return outstanding >= 2 ? .count(outstanding) : nil
  }

  private static func bar(for jobs: [Job], quantum: Double) -> Bar {
    // `min(by:)` keeps the first minimal element, so equal `created` dates
    // break on array order rather than arbitrarily.
    let oldestRunning = jobs
      .filter { $0.status == .running }
      .min { $0.created < $1.created }

    guard let step = oldestRunning.flatMap(JobPresentation.representativeStep) else {
      return .hidden
    }
    guard let fraction = step.progress.fraction else { return .indeterminate }
    return .fraction(quantize(fraction, to: quantum))
  }

  /// Round down to drawable resolution so equivalent snapshots skip redraws without overstating
  /// progress.
  static func quantize(_ fraction: Double, to quantum: Double) -> Double {
    let clamped = min(max(fraction, 0), 1)
    guard quantum > 0 else { return clamped }
    return min((clamped / quantum).rounded(.down) * quantum, 1)
  }
}
