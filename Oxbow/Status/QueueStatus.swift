import Foundation
import OxbowKit

/// Everything the dock tile draws, derived from one `[Job]` snapshot.
///
/// `nonisolated`: the target defaults new declarations to `@MainActor`, but
/// this is a pure value derived from other pure values, with no UI
/// dependency, and `OxbowTests` (which has no actor default of its own) calls
/// it synchronously, which requires it.
///
/// Two channels with two meanings that never overlap — **the bar says how far
/// along, the badge says whether it needs you**. See `docs/design/status.md`
/// §3 for why one number carrying both was rejected.
nonisolated struct QueueStatus: Equatable {

  /// `.alert` beats `.count` outright. There is one badge position, and
  /// between "how many" and "something is wrong" the second wants action.
  enum Badge: Equatable {
    case count(Int)
    case alert
  }

  /// `.indeterminate` is a track with no fill. It is not `.hidden`: an absent
  /// bar reads as idle, which is a lie while a step with no fraction runs.
  enum Bar: Equatable {
    case hidden
    case indeterminate
    case fraction(Double)
  }

  let badge: Badge?
  let bar: Bar

  /// Nothing to draw at all, so the presenter clears the content view and
  /// hands the icon back to the system. See `docs/design/status.md` §5.3 —
  /// this is what makes "is the tile told about appearance changes?" stop
  /// mattering.
  var isIdle: Bool { badge == nil && bar == .hidden }

  init(jobs: [Job], quantum: Double) {
    badge = Self.badge(for: jobs)
    bar = Self.bar(for: jobs, quantum: quantum)
  }

  private static func badge(for jobs: [Job]) -> Badge? {
    if jobs.contains(where: { $0.status == .failed }) { return .alert }

    let outstanding = jobs.count { $0.status == .queued || $0.status == .running }
    // Hidden at one: the bar already tells that story, and "1" would add a
    // glyph without adding information.
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

  /// Snaps a fraction to the bar's drawable resolution, so two snapshots that
  /// would paint the same pixels compare equal and the presenter can skip the
  /// redraw. A render publishes ~400 snapshots; this is what makes throttling
  /// a property of a pure function instead of a timer.
  ///
  /// Rounds **down**, so the bar never overstates progress.
  static func quantize(_ fraction: Double, to quantum: Double) -> Double {
    let clamped = min(max(fraction, 0), 1)
    guard quantum > 0 else { return clamped }
    return min((clamped / quantum).rounded(.down) * quantum, 1)
  }
}
