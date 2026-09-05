import Foundation

/// When a sweep of the watched channels is due.
///
/// Deliberately the same shape as `UpdatePolicy`, which answers the same kind
/// of question about the same kind of stored date, and carries the same guard
/// against a clock that has run backwards. It is not the same *durability*:
/// `UpdateModel` persists `lastChecked` through a `PreferenceStore`, so its
/// throttle survives a relaunch, while `WatchPoller.lastPolled` lives only in
/// memory, so this one's does not — every launch sweeps regardless of when the
/// last one ran. That is intended, not an oversight: §5.1 makes polling at
/// launch the point of the design, not a gap in it.
public enum WatchPollPolicy {

  /// How long a sweep stays satisfied.
  ///
  /// An hour, and the reasoning is that the clock this races is measured in
  /// weeks. `docs/twitch-channel-api.md` §6 measured the shortest surviving
  /// archive window at 43 days, with most partners near 60. Polling more often
  /// buys nothing a user could notice and spends someone else's undocumented
  /// API; polling much less often starts to matter only past several days.
  ///
  /// This is also why `docs/design/channel-watching.md` §5.1 concludes no
  /// background agent is needed: polling at launch and on a timer while the
  /// app runs is enough that a user who opens Oxbow only once a fortnight
  /// still catches everything before it expires.
  public static let interval: TimeInterval = 3600

  /// Whether a sweep should run now.
  ///
  /// A user-initiated refresh deliberately does not consult this, for the same
  /// reason `UpdatePolicy`'s manual check does not: pressing a button is an
  /// explicit request and must always produce an answer.
  public static func shouldPoll(now: Date, lastPolled: Date?) -> Bool {
    guard let lastPolled else { return true }
    // Not `now.timeIntervalSince(lastPolled) >= interval`, which is false for a
    // stored date in the future and would leave a backwards-running clock with
    // polling disabled until real time caught up.
    guard lastPolled <= now else { return true }
    return now.timeIntervalSince(lastPolled) >= interval
  }
}
