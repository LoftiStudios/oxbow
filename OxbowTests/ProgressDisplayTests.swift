import Testing
import OxbowKit
@testable import Oxbow

@Suite("Progress display")
struct ProgressDisplayTests {

  @Test func phaseAndCounterWithoutAPercentageIsIndeterminate() {
    let display = ProgressDisplay(progress: StepProgress(phase: "Fetching Video Info", index: 1, total: 4))

    #expect(display.isIndeterminate)
    #expect(display.fraction == nil)
    #expect(display.phase == "Fetching Video Info")
    #expect(display.counter == "1 of 4")
    #expect(display.remaining == nil)
  }

  @Test func phasePercentageAndCounter() {
    let display = ProgressDisplay(progress: StepProgress(phase: "Downloading", fraction: 1.0, index: 2, total: 4))

    #expect(!display.isIndeterminate)
    #expect(display.fraction == 1.0)
    #expect(display.counter == "2 of 4")
  }

  @Test func phaseAndPercentageWithoutACounter() {
    let display = ProgressDisplay(progress: StepProgress(phase: "Downloading", fraction: 0.25))

    #expect(display.fraction == 0.25)
    #expect(display.counter == nil)
  }

  @Test func phasePercentageAndTimes() {
    let display = ProgressDisplay(progress: StepProgress(
      phase: "Rendering Video",
      fraction: 0.45,
      remaining: .seconds(90)))

    #expect(display.fraction == 0.45)
    #expect(display.remaining == "1m 30s remaining")
  }

  @Test func aZeroRemainingTimeIsNotShown() {
    // The CLI emits 0h0m0s before it has an estimate. Rendering that as
    // "0s remaining" would claim the step is about to finish when it has
    // barely started.
    let display = ProgressDisplay(progress: StepProgress(phase: "Rendering Video", fraction: 0.0, remaining: .seconds(0)))

    #expect(display.remaining == nil)
  }

  @Test func aSubSecondRemainingTimeIsNotShown() {
    // A positive duration that truncates to zero whole seconds (e.g. half a
    // second) must be suppressed the same way an exact zero is — otherwise
    // it renders the same misleading "0s remaining".
    let display = ProgressDisplay(progress: StepProgress(phase: "Rendering Video", fraction: 0.0, remaining: .milliseconds(500)))

    #expect(display.remaining == nil)
  }

  @Test func anEmptyProgressIsIndeterminateAndBlank() {
    let display = ProgressDisplay(progress: StepProgress())

    #expect(display.isIndeterminate)
    #expect(display.phase == nil)
    #expect(display.counter == nil)
    #expect(display.remaining == nil)
  }

  @Test func remainingTimeUnderAMinuteOmitsTheMinutes() {
    let display = ProgressDisplay(progress: StepProgress(remaining: .seconds(45)))

    #expect(display.remaining == "45s remaining")
  }

  @Test func remainingTimeOverAnHourIncludesHours() {
    let display = ProgressDisplay(progress: StepProgress(remaining: .seconds(3661)))

    #expect(display.remaining == "1h 1m remaining")
  }
}
