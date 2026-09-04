import Foundation
import Testing
@testable import OxbowKit

@Suite("RelativeDay")
struct RelativeDayTests {

  /// A fixed calendar in a fixed zone, so a test that passes in London passes
  /// in Auckland. `.current` in production is right — the user's own sense of
  /// "yesterday" is the calendar's, not UTC's — but it makes a test a lottery.
  private var calendar: Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    return calendar
  }

  private let now = Date(timeIntervalSince1970: 1_800_000_000)

  private func phrase(daysAgo days: Int, hours: Int = 0) -> String {
    let then = now.addingTimeInterval(TimeInterval(-days * 86_400 - hours * 3600))
    return RelativeDay.phrase(for: then, now: now, calendar: calendar)
  }

  @Test("the same calendar day reads as today")
  func today() {
    #expect(phrase(daysAgo: 0) == "Published today")
  }

  @Test("the previous calendar day reads as yesterday, not as one day ago")
  func yesterday() {
    #expect(phrase(daysAgo: 1) == "Published yesterday")
  }

  @Test("older reads as a count of days")
  func daysAgo() {
    #expect(phrase(daysAgo: 2) == "Published 2 days ago")
    #expect(phrase(daysAgo: 12) == "Published 12 days ago")
    #expect(phrase(daysAgo: 59) == "Published 59 days ago")
  }

  @Test("it counts calendar days, not elapsed 24-hour periods")
  func countsCalendarDays() {
    // 20 hours ago can be yesterday or today depending on the wall clock, and
    // the user's answer is the calendar's. Anchored deliberately: `now` here
    // is 2027-01-15T08:00:00Z, so 20 hours back is the 14th.
    let anchor = ISO8601DateFormatter().date(from: "2027-01-15T08:00:00Z")!
    let twentyHours = anchor.addingTimeInterval(-20 * 3600)
    #expect(RelativeDay.phrase(for: twentyHours, now: anchor, calendar: calendar)
      == "Published yesterday")
  }

  @Test("a date in the future never becomes a countdown")
  func futureIsNotACountdown() {
    // docs/design/channel-watching.md section 7: there is no expiresAt and
    // retention does not follow from tier, so a countdown would be invented.
    // A future publishedAt is nonsense from the API rather than something to
    // render as "in 3 days" — it degrades to today.
    #expect(phrase(daysAgo: -3) == "Published today")
  }

  @Test("no phrase this produces mentions expiry or remaining time")
  func neverMentionsExpiry() {
    let forbidden = ["expires", "remaining", "left", "in "]
    for days in [0, 1, 2, 30, 90, 400] {
      let text = phrase(daysAgo: days).lowercased()
      for word in forbidden {
        #expect(!text.contains(word), "\(text) contains \(word)")
      }
    }
  }
}
