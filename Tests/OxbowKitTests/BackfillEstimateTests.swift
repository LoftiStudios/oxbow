import Foundation
import Testing
@testable import OxbowKit

@Suite("BackfillEstimate")
struct BackfillEstimateTests {

  private func archive(_ id: String, hours: Double) -> ChannelArchive {
    ChannelArchive(
      id: id, title: "t", duration: .seconds(hours * 3600),
      publishedAt: Date(timeIntervalSince1970: 0), status: .recorded, thumbnailURL: nil)
  }

  @Test("an empty set costs nothing")
  func emptyIsZero() {
    let estimate = BackfillEstimate(archives: [], cap: .best, output: .videoWithChat)
    #expect(estimate.count == 0)
    #expect(estimate.duration == .zero)
    #expect(estimate.bytes == 0)
  }

  @Test("it counts and sums exactly what it was given")
  func sumsWhatItWasGiven() {
    let estimate = BackfillEstimate(
      archives: [archive("1", hours: 2), archive("2", hours: 3)],
      cap: .best, output: .video)
    #expect(estimate.count == 2)
    #expect(estimate.duration == .seconds(5 * 3600))
  }

  @Test("a lower cap costs less")
  func lowerCapCostsLess() {
    let archives = [archive("1", hours: 5)]
    let best = BackfillEstimate(archives: archives, cap: .best, output: .video)
    let low = BackfillEstimate(archives: archives, cap: .p360, output: .video)
    #expect(low.bytes < best.bytes)
  }

  @Test("with-chat's peak overhead includes the chat render, so it prices higher than plain video")
  func chatAddsRenderOverheadToThePeak() {
    // Peak-aware cost is delivered sum plus maximum transient overhead. Chat's render
    // intermediate must make its single-job peak exceed video-only.
    let archives = [archive("1", hours: 5)]
    let plain = BackfillEstimate(archives: archives, cap: .p720, output: .video)
    let withChat = BackfillEstimate(archives: archives, cap: .p720, output: .videoWithChat)
    #expect(plain.bytes > 0)
    #expect(withChat.bytes > plain.bytes)
  }

  @Test(
    "the nominal bitrate ladder produces the expected byte figures, per cap",
    arguments: [
      // Cap, nominal bitrate, and one-hour video-only size (`bitsPerSecond * 3600 / 8`).
      (QualityCap.best, 6_000_000, Int64(2_700_000_000)),
      (QualityCap.p1080, 6_000_000, Int64(2_700_000_000)),
      (QualityCap.p720, 3_500_000, Int64(1_575_000_000)),
      (QualityCap.p480, 1_400_000, Int64(630_000_000)),
      (QualityCap.p360, 700_000, Int64(315_000_000)),
    ]
  )
  func nominalBitrateLadder(cap: QualityCap, bitsPerSecond: Int, expectedBytes: Int64) {
    // Compute size from the independently listed rate to catch errors in nominal quality
    // values.
    #expect(expectedBytes == Int64(bitsPerSecond) * 3600 / 8)

    let estimate = BackfillEstimate(archives: [archive("1", hours: 1)], cap: cap, output: .video)
    let tolerance = Int64(1) // exact arithmetic at this duration; no rounding slack needed
    #expect(abs(estimate.bytes - expectedBytes) <= tolerance)
  }

  @Test("cost scales with duration")
  func scalesWithDuration() {
    let short = BackfillEstimate(archives: [archive("1", hours: 1)], cap: .p720, output: .video)
    let long = BackfillEstimate(archives: [archive("1", hours: 10)], cap: .p720, output: .video)
    #expect(long.bytes > short.bytes * 5)
  }

  @Test("a live broadcast is priced on what has aired, not skipped")
  func liveIsPricedNotSkipped() {
    // Include recording broadcasts at their currently known duration rather than dropping them
    // from backfill estimates.
    let live = ChannelArchive(
      id: "1", title: "t", duration: .seconds(3600),
      publishedAt: Date(timeIntervalSince1970: 0), status: .recording, thumbnailURL: nil)
    let estimate = BackfillEstimate(archives: [live], cap: .best, output: .video)
    #expect(estimate.count == 1)
    #expect(estimate.duration == .seconds(3600))
    #expect(estimate.bytes > 0)
  }
}
