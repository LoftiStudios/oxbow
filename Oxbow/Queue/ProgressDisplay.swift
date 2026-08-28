import Foundation
import OxbowKit

/// What one row draws, derived from a `StepProgress` whose every field is
/// optional because the CLI emits four different status line shapes.
///
/// `nonisolated`: the target defaults new declarations to `@MainActor`, but
/// this is a pure value derived from another pure value, with no UI
/// dependency, so it should be free to compute off the main actor too.
nonisolated struct ProgressDisplay {
  let fraction: Double?
  let phase: String?
  let counter: String?
  let remaining: String?
  let rate: String?

  var isIndeterminate: Bool { fraction == nil }

  init(progress: StepProgress) {
    fraction = progress.fraction
    phase = progress.phase

    if let index = progress.index, let total = progress.total {
      counter = "\(index) of \(total)"
    } else {
      counter = nil
    }

    remaining = Self.format(progress.remaining)
    rate = Self.format(rate: progress.speed)
  }

  /// Nil for absent durations and any duration that would render as "0s".
  /// The CLI emits `0h0m0s Remaining` before it has an estimate, and
  /// "0s remaining" would claim a step is about to finish when it has
  /// barely started — true whether the duration is exactly zero or just
  /// truncates to zero whole seconds.
  private static func format(_ duration: Duration?) -> String? {
    guard let duration else { return nil }

    let total = Int(duration.components.seconds)
    guard total > 0 else { return nil }

    let hours = total / 3600
    let minutes = (total % 3600) / 60
    let seconds = total % 60

    let value = if hours > 0 {
      "\(hours)h \(minutes)m"
    } else if minutes > 0 {
      "\(minutes)m \(seconds)s"
    } else {
      "\(seconds)s"
    }
    return "\(value) remaining"
  }

  /// Nil below a hundredth — FFmpeg's own degenerate `0.00x` before it has
  /// measured anything, which is worth hiding rather than showing "0.0x" and
  /// reading as a stalled encoder when it is only an unstarted one.
  private static func format(rate: Double?) -> String? {
    guard let rate, rate >= 0.01 else { return nil }
    return String(format: "%.1fx realtime", rate)
  }
}
