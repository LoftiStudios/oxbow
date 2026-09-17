import CoreGraphics
import Foundation

/// Timeline tick, label, and drag arithmetic. Fixed 72 subdivisions align every label with a
/// major tick without rounding.
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

  /// Guard truncated totalSeconds, not Duration: sub-second durations otherwise divide by zero.
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

  /// Round drag increments to familiar time units.
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

  /// Return a snapped time clamped to the video's bounds, even when a drag leaves the track.
  func time(atX x: CGFloat) -> Duration {
    guard isDrawable else { return .zero }
    return snapped(min(max(Double(x / width), 0), 1) * totalSeconds)
  }

  /// Include the true endpoint as a snap stop so the final partial drag unit remains reachable.
  func snapped(_ seconds: Double) -> Duration {
    let unit = Double(dragUnitSeconds)
    let grid = min(max((seconds / unit).rounded() * unit, 0), totalSeconds)
    guard abs(seconds - totalSeconds) < abs(seconds - grid) else { return .seconds(Int(grid)) }
    return duration
  }

  /// Measured width of eight characters in 11pt Monaco; keep consistent with label font and
  /// format.
  static let labelWidth: CGFloat = 52.81
  static let minLabelGap: CGFloat = 8

  enum LabelAnchor: Equatable { case leading, center, trailing }
  struct Label: Equatable {
    let x: CGFloat
    let text: String
    let anchor: LabelAnchor
  }

  var labels: [Label] {
    guard isDrawable else { return [] }
    let steps = labelSteps
    return steps.enumerated().map { index, step in
      Label(
        x: x(atStep: step),
        text: Timecode.format(time(atStep: step)),
        anchor: index == 0 ? .leading : (index == steps.count - 1 ? .trailing : .center))
    }
  }

  /// Keep endpoints exact; snap only interior labels.
  private func time(atStep step: Int) -> Duration {
    if step == 0 { return .zero }
    if step == Self.subdivisions { return duration }
    return snapped(totalSeconds * Double(step) / Double(Self.subdivisions))
  }

  /// Drop labels from the same five positions when narrowing, preserving alignment with major
  /// ticks.
  private var labelSteps: [Int] {
    let five = Array(stride(from: 0, through: Self.subdivisions, by: Self.labelEvery))
    if fits(five.count) { return five }
    if fits(3) { return [0, Self.subdivisions / 2, Self.subdivisions] }
    return [0, Self.subdivisions]
  }

  private func fits(_ count: Int) -> Bool {
    CGFloat(count) * Self.labelWidth + CGFloat(count - 1) * Self.minLabelGap <= width
  }
}
