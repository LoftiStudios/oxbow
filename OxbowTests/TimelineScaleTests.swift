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

  /// One pixel's worth of time, rounded up to something round. A person
  /// dragging on a six-hour VOD cannot land on a second no matter what the
  /// control does, so the readout may as well be a number they meant.
  @Test func picksADragUnitFromTimePerPoint() {
    #expect(TimelineScale(duration: .seconds(180), width: 500).dragUnitSeconds == 1)
    #expect(TimelineScale(duration: .seconds(991), width: 500).dragUnitSeconds == 2)
    #expect(TimelineScale(duration: .seconds(2400), width: 500).dragUnitSeconds == 5)
    #expect(TimelineScale(duration: .seconds(11863), width: 500).dragUnitSeconds == 30)
    #expect(TimelineScale(duration: .seconds(21600), width: 500).dragUnitSeconds == 60)
  }

  @Test func projectsTheEndsToTheEdges() {
    let scale = TimelineScale(duration: Self.fortyMinutes, width: 500)
    #expect(scale.x(for: .zero) == 0)
    #expect(scale.x(for: Self.fortyMinutes) == 500)
  }

  @Test func roundTripsEveryValueOnTheDragGrid() {
    let scale = TimelineScale(duration: Self.fortyMinutes, width: 500)
    for seconds in stride(from: 0, through: 2400, by: scale.dragUnitSeconds) {
      let time = Duration.seconds(seconds)
      #expect(scale.time(atX: scale.x(for: time)) == time)
    }
  }

  /// The end of the video is a stop even when it is not on the grid. Without
  /// it the snap rounds down and the last partial unit is unreachable: this
  /// VOD on a 30s unit would stop at 03:17:30, under a label reading 03:17:43.
  @Test func theEndOfTheVideoIsAlwaysReachable() {
    let scale = TimelineScale(duration: .seconds(11863), width: 500)
    #expect(scale.time(atX: 500) == .seconds(11863))
  }

  @Test func clampsRatherThanExtrapolatingOutsideTheTrack() {
    let scale = TimelineScale(duration: Self.fortyMinutes, width: 500)
    #expect(scale.time(atX: -80) == .zero)
    #expect(scale.time(atX: 900) == Self.fortyMinutes)
  }

  @Test func projectsToZeroWithoutADurationOrAWidth() {
    #expect(TimelineScale(duration: .zero, width: 500).x(for: .seconds(5)) == 0)
    #expect(TimelineScale(duration: .zero, width: 500).time(atX: 10) == .zero)
  }
}
