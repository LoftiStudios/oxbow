import Foundation
import Testing
@testable import OxbowKit

@Suite("Video length")
struct VideoLengthTests {

  /// Under an hour, the hour field is dropped rather than shown as a leading
  /// zero — the shape a video player uses.
  @Test("under an hour reads as minutes and seconds")
  func underAnHour() {
    #expect(VideoLength.timecode(.seconds(90)) == "1:30")
    #expect(VideoLength.timecode(.seconds(16 * 60 + 31)) == "16:31")
  }

  @Test("an hour or more gains the hour field")
  func anHourOrMore() {
    #expect(VideoLength.timecode(.seconds(3 * 3600 + 12 * 60 + 4)) == "3:12:04")
  }

  /// The boundary, because it is where the two branches meet and an off-by-one
  /// here would render an hour-long video as "60:00".
  @Test("exactly one hour crosses into the hour field")
  func exactlyOneHour() {
    #expect(VideoLength.timecode(.seconds(3600)) == "1:00:00")
    #expect(VideoLength.timecode(.seconds(3599)) == "59:59")
  }

  /// A zero-length archive is not worth a special case, but it must not
  /// produce an empty string where a row expects a value.
  @Test("zero still renders something")
  func zero() {
    #expect(VideoLength.timecode(.seconds(0)) == "0:00")
  }
}
