import Foundation

/// Sweep throttle with clock-rollback handling. Unlike update checks, its last-polled time is
/// not persisted: every launch sweeps.
public enum WatchPollPolicy {

  /// One-hour interval while the app runs; launch also triggers a sweep. See
  /// `docs/design/channel-watching.md` §5.1.
  public static let interval: TimeInterval = 3600

  /// Whether an automatic sweep is due. Manual refresh bypasses this throttle.
  public static func shouldPoll(now: Date, lastPolled: Date?) -> Bool {
    guard let lastPolled else { return true }
    // A future last-polled date must not disable polling after clock rollback.
    guard lastPolled <= now else { return true }
    return now.timeIntervalSince(lastPolled) >= interval
  }
}
