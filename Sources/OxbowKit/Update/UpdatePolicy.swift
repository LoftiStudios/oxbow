import Foundation

/// The two decisions around an update check that are pure functions of stored
/// state, kept out of the view layer so they can be tested without one.
public enum UpdatePolicy {

  /// How long an automatic check stays satisfied. A day, because a release
  /// worth installing is not worth installing within the hour, and because
  /// unauthenticated api.github.com allows 60 requests an hour per IP —
  /// a budget shared with everything else on the network.
  public static let interval: TimeInterval = 24 * 3600

  /// Whether the launch-time check should run at all.
  ///
  /// The manual menu item deliberately does not consult this: pressing it is
  /// an explicit request and must always produce an answer.
  public static func shouldCheckAutomatically(now: Date, lastChecked: Date?) -> Bool {
    guard let lastChecked else { return true }
    // Not `now.timeIntervalSince(lastChecked) >= interval`, which is false for
    // a stored date in the future and would leave a backwards-running clock
    // with the check disabled until real time caught up.
    guard lastChecked <= now else { return true }
    return now.timeIntervalSince(lastChecked) >= interval
  }

  /// Whether an outcome is worth putting on screen.
  ///
  /// `skipping` is compared with `==`, not `<=`. Dismissing the banner means
  /// "not this one", so a later release must bring it back — a dismissal that
  /// suppressed everything above it would turn the feature off permanently and
  /// silently.
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
