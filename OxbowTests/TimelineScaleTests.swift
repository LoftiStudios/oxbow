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

  /// The tallies above would pass with every tick in the wrong place. This
  /// pins the mapping itself: 18 is a multiple of both 3 and 18, which is the
  /// property the whole scheme rests on.
  @Test func mapsEachStepToItsHeight() {
    #expect(TimelineScale.height(atStep: 0) == .label)
    #expect(TimelineScale.height(atStep: 3) == .major)
    #expect(TimelineScale.height(atStep: 18) == .label)
    #expect(TimelineScale.height(atStep: 71) == .minor)
    #expect(TimelineScale.height(atStep: 72) == .label)
  }

  @Test func spacesTicksEvenlyAcrossTheTrack() {
    let ticks = TimelineScale(duration: Self.fortyMinutes, width: 720).ticks
    #expect(ticks[18].x == 180)
    #expect(ticks[36].x == 360)
    #expect(ticks[54].x == 540)
  }
}
