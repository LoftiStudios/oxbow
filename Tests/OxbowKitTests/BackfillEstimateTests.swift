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

  @Test("chat costs more than video alone at the same cap")
  func chatCostsMore() {
    let archives = [archive("1", hours: 5)]
    let plain = BackfillEstimate(archives: archives, cap: .p720, output: .video)
    let withChat = BackfillEstimate(archives: archives, cap: .p720, output: .videoWithChat)
    #expect(withChat.bytes > plain.bytes)
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
    #expect(BackfillEstimate(archives: [live], cap: .best, output: .video).count == 1)
  }

  @Test("the estimate is a function of the archives given, with no count to read")
  func hasNoCountToMisread() throws {
    // docs/twitch-channel-api.md section 5.1: `totalCount` overcounts the
    // edges actually returned by up to two. Section 3.3 of the design doc
    // therefore requires the estimate be summed from the archives in hand.
    // This type takes only `[ChannelArchive]`, so there is no count for a
    // caller to reach for by mistake — pinned here so a future convenience
    // initialiser taking a total does not quietly appear.
    let source = try String(
      contentsOf: URL(filePath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appending(path: "Sources/OxbowKit/Model/BackfillEstimate.swift"),
      encoding: .utf8)
    #expect(!source.contains("totalCount"))
  }
}
