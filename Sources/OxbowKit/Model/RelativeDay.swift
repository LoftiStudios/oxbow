import Foundation

/// Formats publication age. Twitch metadata cannot predict expiry; see
/// `docs/twitch-channel-api.md` §6.
public enum RelativeDay {

  /// Age in calendar days, using the caller's time zone. `includingVerb` prefixes “Published”
  /// for a standalone sentence.
  public static func phrase(
    for date: Date, now: Date, calendar: Calendar = .current,
    includingVerb: Bool = true) -> String
  {
    let days = calendar.dateComponents(
      [.day],
      from: calendar.startOfDay(for: date),
      to: calendar.startOfDay(for: now)).day ?? 0

    // Treat future dates as today. Capitalize when the verb is omitted.
    switch days {
    case ..<1: return includingVerb ? "Published today" : "Today"
    case 1: return includingVerb ? "Published yesterday" : "Yesterday"
    default:
      let age = "\(days) days ago"
      return includingVerb ? "Published \(age)" : age
    }
  }
}
