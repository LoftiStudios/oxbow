import Foundation
import Testing
@testable import Oxbow

@Suite("Timecode")
struct TimecodeTests {

  @Test func formatsZeroPaddedHoursMinutesAndSeconds() {
    #expect(Timecode.format(.seconds(0)) == "00:00:00")
    #expect(Timecode.format(.seconds(600)) == "00:10:00")
    #expect(Timecode.format(.seconds(11863)) == "03:17:43")
  }

  /// The drag writes what `format` produces straight into the text fields the
  /// user can also type in, so the two have to agree. `Duration.formatted`
  /// would give `0:10:00`, which is why this is hand-rolled.
  @Test func everyFormattedValueParsesBackToItself() {
    for seconds in stride(from: 0, through: 6 * 3600, by: 37) {
      let duration = Duration.seconds(seconds)
      #expect(Timecode.parse(Timecode.format(duration)) == duration)
    }
  }

  @Test func clampsNegativeDurationsToZero() {
    #expect(Timecode.format(.seconds(-5)) == "00:00:00")
    #expect(Timecode.spelled(.seconds(-5)) == "00h 00m 00s")
  }

  /// The trim section's duration row, which is read rather than typed — so it
  /// spells its units out instead of reusing the field format above.
  @Test func spellsOutTheUnitsForTheDurationReadout() {
    #expect(Timecode.spelled(.seconds(0)) == "00h 00m 00s")
    #expect(Timecode.spelled(.seconds(2400)) == "00h 40m 00s")
    #expect(Timecode.spelled(.seconds(11863)) == "03h 17m 43s")
  }
}
