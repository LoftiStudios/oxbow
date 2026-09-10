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
  /// - Parameter includingVerb: whether to lead with "Published".
  ///   Defaulted on, because every caller but one is writing a standalone
  ///   sentence. The Watching row is the exception: it sets this line beside
  ///   a duration — "19 days ago · 1:31" — where a verb reads as a sentence
  ///   fragment against a bare number.
  public static func phrase(
    for date: Date, now: Date, calendar: Calendar = .current,
    includingVerb: Bool = true) -> String
  {
    let days = calendar.dateComponents(
      [.day],
      from: calendar.startOfDay(for: date),
      to: calendar.startOfDay(for: now)).day ?? 0

    // A negative age means Twitch gave us a publish date in the future, which
    // is nonsense rather than something to render. Degrading to "today" keeps
    // the promise that nothing here ever counts down.
    // Capitalised when the verb is gone, because this then starts its own
    // line rather than continuing "Published …". "days ago" needs no such
    // treatment: it leads with a number either way.
    switch days {
    case ..<1: return includingVerb ? "Published today" : "Today"
    case 1: return includingVerb ? "Published yesterday" : "Yesterday"
    default:
      let age = "\(days) days ago"
      return includingVerb ? "Published \(age)" : age
    }
  }
}
