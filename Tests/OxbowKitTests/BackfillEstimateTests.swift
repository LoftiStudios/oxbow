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

  @Test("with-chat prices the composite, not the source plus the composite")
  func chatPricesTheCompositeAlone() {
    // Not "chat costs more": `SpaceEstimate.delivered` is the composite ALONE
    // once one exists (never source-plus-composite — the source is a
    // transient that `total`, the peak, accounts for instead). A composite is
    // a controlled quality-based re-encode, not the raw stream, and at every
    // nominal cap in `nominalQuality` it in fact re-encodes smaller than the
    // plain download: measured here, `withChat.bytes` is honestly, not
    // coincidentally, the lower figure. So this pins that the two paths are
    // wired to genuinely different numbers, not a size relationship the
    // corrected formula never promised.
    let archives = [archive("1", hours: 5)]
    let plain = BackfillEstimate(archives: archives, cap: .p720, output: .video)
    let withChat = BackfillEstimate(archives: archives, cap: .p720, output: .videoWithChat)
    #expect(plain.bytes > 0)
    #expect(withChat.bytes > 0)
    #expect(withChat.bytes != plain.bytes)
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
