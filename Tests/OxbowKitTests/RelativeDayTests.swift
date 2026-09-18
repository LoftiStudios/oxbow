import Foundation
import Testing
@testable import OxbowKit

@Suite("RelativeDay")
struct RelativeDayTests {

  /// Fixed calendar and zone keep relative dates independent of the test machine.
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
    // At 08:00 UTC on Jan 15, twenty hours earlier falls on Jan 14.
    let anchor = ISO8601DateFormatter().date(from: "2027-01-15T08:00:00Z")!
    let twentyHours = anchor.addingTimeInterval(-20 * 3600)
    #expect(RelativeDay.phrase(for: twentyHours, now: anchor, calendar: calendar)
      == "Published yesterday")
  }

  @Test("a date in the future never becomes a countdown")
  func futureIsNotACountdown() {
    // Future publication dates degrade to today; never infer an expiry countdown.
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

  // MARK: - Without the verb

  /// Rows can omit “Published” when combining age with duration.
  @Test func dropsTheVerbWhenAsked() {
    let calendar = Calendar(identifier: .gregorian)
    let now = Date(timeIntervalSince1970: 1_000_000)
    let threeDays = now.addingTimeInterval(-3 * 24 * 60 * 60)

    #expect(RelativeDay.phrase(
      for: threeDays, now: now, calendar: calendar, includingVerb: false) == "3 days ago")
    #expect(RelativeDay.phrase(
      for: threeDays, now: now, calendar: calendar) == "Published 3 days ago")
  }

  /// Verb-free today/yesterday still need complete, capitalized labels.
  @Test func todayAndYesterdaySurviveLosingTheVerb() {
    let calendar = Calendar(identifier: .gregorian)
    let now = Date(timeIntervalSince1970: 1_000_000)

    #expect(RelativeDay.phrase(
      for: now, now: now, calendar: calendar, includingVerb: false) == "Today")
    #expect(RelativeDay.phrase(
      for: now.addingTimeInterval(-24 * 60 * 60), now: now,
      calendar: calendar, includingVerb: false) == "Yesterday")
  }
}
