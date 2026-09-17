import Foundation

/// The two decisions around an update check that are pure functions of stored
/// state, kept out of the view layer so they can be tested without one.
public enum UpdatePolicy {

  /// One-day automatic-check interval to limit use of GitHub's shared unauthenticated quota.
  public static let interval: TimeInterval = 24 * 3600

  /// Launch-check throttle. Manual checks bypass it.
  public static func shouldCheckAutomatically(now: Date, lastChecked: Date?) -> Bool {
    guard let lastChecked else { return true }
    // A future last-check date must not disable checks after clock rollback.
    guard lastChecked <= now else { return true }
    return now.timeIntervalSince(lastChecked) >= interval
  }

  /// Dismissal suppresses only that exact version, so a later release can show the banner
  /// again.
  public static func shouldPresent(
    _ outcome: UpdateCheck.Outcome,
    skipping skipped: ReleaseVersion?)
    -> Bool
  {
    switch outcome {
    case .upToDate:
      return false
    case .available(let version, _):
      return version != skipped
    }
  }
}
