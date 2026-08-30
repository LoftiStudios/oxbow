import CoreGraphics
import Foundation
import Testing
@testable import Oxbow

@Suite("Timeline scale")
struct TimelineScaleTests {

  private static let fortyMinutes = Duration.seconds(2400)

  /// 73 ticks over 72 subdivisions. 72 is chosen because it divides by 3 and
  /// by 18, which is what makes the label positions a subset of the major
  /// positions with no rounding — see the design doc §3.1.
  @Test func drawsSeventyThreeTicksInThreeHeights() {
    let ticks = TimelineScale(duration: Self.fortyMinutes, width: 500).ticks
    #expect(ticks.count == 73)
    #expect(ticks.filter { $0.height == .label }.count == 5)
    #expect(ticks.filter { $0.height == .major }.count == 20)
    #expect(ticks.filter { $0.height == .minor }.count == 48)
  }

  /// The spec counts 25 majors; 5 of them carry a label and are drawn taller.
  @Test func fiveOfTheTwentyFiveMajorsCarryALabel() {
    let ticks = TimelineScale(duration: Self.fortyMinutes, width: 500).ticks
    let majorOrTaller = ticks.filter { $0.height == .label || $0.height == .major }
    #expect(majorOrTaller.count == 25)
  }

  @Test func spansTheFullWidthEndToEnd() {
    let ticks = TimelineScale(duration: Self.fortyMinutes, width: 500).ticks
    #expect(ticks.first?.x == 0)
    #expect(ticks.last?.x == 500)
  }

  /// Both are reachable on the first layout pass, before geometry is measured.
  @Test func drawsNothingWithoutADurationOrAWidth() {
    #expect(TimelineScale(duration: .zero, width: 500).ticks.isEmpty)
    #expect(TimelineScale(duration: Self.fortyMinutes, width: 0).ticks.isEmpty)
  }
}
