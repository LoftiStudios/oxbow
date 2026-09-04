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
    // A clock that ran backwards — a timezone change, a corrected NTP sync, a
    // restored backup — must not leave polling switched off for however long
    // the discrepancy is. UpdatePolicy carries the same guard.
    #expect(WatchPollPolicy.shouldPoll(now: now, lastPolled: now.addingTimeInterval(3600)))
  }

  @Test("the interval is well under the shortest measured retention window")
  func intervalIsFarInsideTheExpiryClock() {
    // docs/twitch-channel-api.md section 6 measured the shortest surviving
    // archive window at 43 days. An hour is three orders of magnitude inside
    // it; this pins that the interval never drifts into the same order as the
    // thing it is racing.
    #expect(WatchPollPolicy.interval <= 6 * 3600)
  }
}
