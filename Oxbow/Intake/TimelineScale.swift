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

  /// Both are zero at least once before geometry is measured, and the
  /// projection methods below divide by `totalSeconds`. Guarding on the
  /// seconds rather than on `duration` itself is deliberate: `totalSeconds`
  /// truncates, so a sub-second duration would pass a `duration > .zero`
  /// check and reach that division as a zero.
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

  /// Rounded up to one of these rather than to the raw time-per-point, so a
  /// drag produces `00:10:00` and not `00:09:47`.
  static let niceUnits = [1, 2, 5, 10, 15, 30, 60, 120, 300, 600]

  var dragUnitSeconds: Int {
    guard isDrawable else { return 1 }
    let perPoint = totalSeconds / Double(width)
    return Self.niceUnits.first { Double($0) >= perPoint } ?? Self.niceUnits[Self.niceUnits.count - 1]
  }

  var dragUnit: Duration { .seconds(dragUnitSeconds) }

  func x(for time: Duration) -> CGFloat {
    guard isDrawable else { return 0 }
    let seconds = min(max(Double(time.components.seconds), 0), totalSeconds)
    return width * CGFloat(seconds / totalSeconds)
  }

  /// Already rounded, so no caller has to remember to. Clamped rather than
  /// extrapolated: a drag can leave the track, and a time past the end of the
  /// video reaches the CLI as an argument that fails minutes into a download.
  func time(atX x: CGFloat) -> Duration {
    guard isDrawable else { return .zero }
    return snapped(min(max(Double(x / width), 0), 1) * totalSeconds)
  }

  /// The stop nearest `seconds`, where the stops are every `dragUnit` **plus
  /// the true end of the video**. That last stop is not decoration: without it
  /// the snap rounds down and the final partial unit cannot be reached at all
  /// — a 3:17:43 VOD on a 30s unit stops at 03:17:30, under a label that
  /// correctly reads 03:17:43. So the last stop sits closer to its neighbour
  /// than a full unit, the same asymmetry the endpoint labels have.
  func snapped(_ seconds: Double) -> Duration {
    let unit = Double(dragUnitSeconds)
    let grid = min(max((seconds / unit).rounded() * unit, 0), totalSeconds)
    guard abs(seconds - totalSeconds) < abs(seconds - grid) else { return .seconds(Int(grid)) }
    return duration
  }
}
