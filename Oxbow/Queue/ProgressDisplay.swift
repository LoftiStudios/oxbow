import Foundation
import OxbowKit

/// Presentation of optional StepProgress fields, independent of the main actor.
nonisolated struct ProgressDisplay {
  let fraction: Double?
  let phase: String?
  let counter: String?
  let remaining: String?
  let rate: String?
  /// Projected output size during quality-targeted encoding, whose final size cannot be known
  /// in advance. See docs/design/composite-rate-control.md §7.1.
  let projectedSize: String?

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

    // Label the projection approximate.
    projectedSize = progress.projectedBytes.map {
      "about \(Int64($0).formatted(.byteCount(style: .file)))"
    }
  }

  /// Hide absent durations and values rounding to 0s; the CLI emits zero before an estimate is
  /// available.
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

  /// Hide FFmpeg's initial near-zero rate until it has a meaningful measurement.
  private static func format(rate: Double?) -> String? {
    guard let rate, rate >= 0.01 else { return nil }
    return String(format: "%.1fx realtime", rate)
  }
}
