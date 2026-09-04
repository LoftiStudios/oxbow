import Foundation

/// How long ago something was published, as a phrase.
///
/// **An age, never a countdown.** `docs/design/channel-watching.md` §7: there
/// is no `expiresAt` on a Twitch video, `deletedAt` is null until the video is
/// already gone, and `docs/twitch-channel-api.md` §6 measured retention
/// ranging from 43 days to over nine months with no field predicting which. A
/// "expires in 3 days" would therefore be invented. "Published 12 days ago" is
/// derivable, true, and nearly as useful for deciding what to grab first.
public enum RelativeDay {

  /// `date`'s age relative to `now`, in calendar days.
  ///
  /// **Calendar days, not elapsed 24-hour periods.** Twenty hours ago is
  /// "yesterday" or "today" depending on the wall clock, and the answer a
  /// person wants is the one their calendar gives. `.current` by default for
  /// that reason; tests pass a fixed one so they do not depend on where they
  /// run.
  public static func phrase(
    for date: Date, now: Date, calendar: Calendar = .current) -> String
  {
    let days = calendar.dateComponents(
      [.day],
      from: calendar.startOfDay(for: date),
      to: calendar.startOfDay(for: now)).day ?? 0

    // A negative age means Twitch gave us a publish date in the future, which
    // is nonsense rather than something to render. Degrading to "today" keeps
    // the promise that nothing here ever counts down.
    switch days {
    case ..<1: return "Published today"
    case 1: return "Published yesterday"
    default: return "Published \(days) days ago"
    }
  }
}
