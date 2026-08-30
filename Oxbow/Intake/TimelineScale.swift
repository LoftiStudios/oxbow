import CoreGraphics
import Foundation

/// The arithmetic behind the trim timeline: where its ticks and labels go, and
/// how far a drag has to move to change anything.
///
/// Pure and `nonisolated` on purpose. Every rule the ruler obeys lives here and
/// is tested directly, so `TrimTimeline` can be a dumb rendering of it — the
/// same split `IntakeModel` and `IntakeWindow` already use.
///
/// **The tick count is fixed, not derived from the duration.** 72 subdivisions
/// divides by 3 (majors) and by 18 (labels), so every label sits exactly on a
/// major tick with no rounding and no special case. A count computed from the
/// duration would buy nothing and would make that guarantee conditional.
nonisolated struct TimelineScale: Equatable {
  static let subdivisions = 72
  static let majorEvery = 3
  static let labelEvery = 18

  enum TickHeight: Equatable { case label, major, minor }
  struct Tick: Equatable {
    let x: CGFloat
    let height: TickHeight
  }

  let duration: Duration
  let width: CGFloat

  /// Both are zero at least once before geometry is measured. This guard
  /// enables Task 3's `x(for:)` and `time(atX:)` to divide by `totalSeconds`
  /// safely.
  var isDrawable: Bool { width > 0 && totalSeconds > 0 }

  var totalSeconds: Double { Double(duration.components.seconds) }

  static func height(atStep step: Int) -> TickHeight {
    if step % labelEvery == 0 { return .label }
    if step % majorEvery == 0 { return .major }
    return .minor
  }

  var ticks: [Tick] {
    guard isDrawable else { return [] }
    return (0...Self.subdivisions).map { step in
      Tick(x: x(atStep: step), height: Self.height(atStep: step))
    }
  }

  func x(atStep step: Int) -> CGFloat {
    width * CGFloat(step) / CGFloat(Self.subdivisions)
  }
}
