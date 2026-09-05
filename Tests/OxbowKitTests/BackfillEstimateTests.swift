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
    // Under the corrected formula `bytes = Σ delivered + max(total - delivered)`,
    // `.videoWithChat`'s single-archive `total - delivered` includes
    // `SpaceEstimate.chatRender` (the transient render the source-plus-chat
    // job tears down before delivering the composite) on top of the source
    // overhead a plain download already carries. So — unlike the old,
    // delivered-only formula this replaces, where the composite could price
    // *below* the plain download — the with-chat figure is pinned here to
    // come out strictly higher, because the peak term now actually reflects
    // what a with-chat job holds mid-flight.
    let archives = [archive("1", hours: 5)]
    let plain = BackfillEstimate(archives: archives, cap: .p720, output: .video)
    let withChat = BackfillEstimate(archives: archives, cap: .p720, output: .videoWithChat)
    #expect(plain.bytes > 0)
    #expect(withChat.bytes > plain.bytes)
  }

  @Test(
    "the nominal bitrate ladder produces the expected byte figures, per cap",
    arguments: [
      // cap, nominal bits/sec (from `nominalQuality`), expected bytes for a
      // 1-hour archive at `.video` (source only, so bytes == source
      // == bitsPerSecond * 3600 / 8 exactly — no chat/composite term to
      // muddy a direct read of the ladder).
      (QualityCap.best, 6_000_000, Int64(2_700_000_000)),
      (QualityCap.p1080, 6_000_000, Int64(2_700_000_000)),
      (QualityCap.p720, 3_500_000, Int64(1_575_000_000)),
      (QualityCap.p480, 1_400_000, Int64(630_000_000)),
      (QualityCap.p360, 700_000, Int64(315_000_000)),
    ]
  )
  func nominalBitrateLadder(cap: QualityCap, bitsPerSecond: Int, expectedBytes: Int64) {
    // Table asserted against a computed rather than merely restated
    // expectation, so a typo in `nominalQuality` (e.g. 1_400_000 becoming
    // 14_000_000) fails this even though the hand-written column above would
    // silently "agree" with the same typo if copied from the source.
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
    // A RECORDING node's lengthSeconds describes only what has aired so far.
    // Pricing it on that is the honest available number; dropping it from the
    // total would understate a backfill the user can still choose to take.
    let live = ChannelArchive(
      id: "1", title: "t", duration: .seconds(3600),
      publishedAt: Date(timeIntervalSince1970: 0), status: .recording, thumbnailURL: nil)
    let estimate = BackfillEstimate(archives: [live], cap: .best, output: .video)
    #expect(estimate.count == 1)
    #expect(estimate.duration == .seconds(3600))
    #expect(estimate.bytes > 0)
  }
}
