import Foundation
import Testing
@testable import OxbowKit

@Suite("WatchPollPolicy")
struct WatchPollPolicyTests {

  private let now = Date(timeIntervalSince1970: 1_800_000_000)

  @Test("a channel never polled is due immediately")
  func neverPolledIsDue() {
    #expect(WatchPollPolicy.shouldPoll(now: now, lastPolled: nil))
  }

  @Test("a sweep just done is not due again")
  func recentIsNotDue() {
    #expect(!WatchPollPolicy.shouldPoll(now: now, lastPolled: now.addingTimeInterval(-60)))
  }

  @Test("a sweep older than the interval is due")
  func staleIsDue() {
    let stale = now.addingTimeInterval(-WatchPollPolicy.interval - 1)
    #expect(WatchPollPolicy.shouldPoll(now: now, lastPolled: stale))
  }

  @Test("exactly at the interval is due")
  func exactlyAtIntervalIsDue() {
    let boundary = now.addingTimeInterval(-WatchPollPolicy.interval)
    #expect(WatchPollPolicy.shouldPoll(now: now, lastPolled: boundary))
  }

  @Test("a last-polled date in the future is due, not disabled until time catches up")
  func futureDateIsDue() {
    // Clock rollback must not disable polling until the stored date catches up.
    #expect(WatchPollPolicy.shouldPoll(now: now, lastPolled: now.addingTimeInterval(3600)))
  }

  @Test("the interval is well under the shortest measured retention window")
  func intervalIsFarInsideTheExpiryClock() {
    // Bound polling far below the archive retention windows measured in `twitch-channel-api.md`
    // §6.
    #expect(WatchPollPolicy.interval <= 6 * 3600)
  }
}
