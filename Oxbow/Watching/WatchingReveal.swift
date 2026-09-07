import Observation

/// A request, from outside the view hierarchy, that the queue window show the
/// Watching pane.
///
/// **Why a shared object rather than the `@State`-in-`OxbowApp` hand-off the
/// app uses everywhere else.** `pendingIntake` and `pendingChannelEdit` are
/// both set from inside `body` — a closure the scene itself builds — so a
/// `@State` on the `App` is reachable. This one is set from
/// `JobNotifier`'s `UNUserNotificationCenterDelegate` callback, which is a
/// `nonisolated` method on an object the scene never sees. An `App` is a
/// value type re-created on every state change; there is nothing there for a
/// delegate to hold on to.
///
/// **A counter, not a `Bool`.** A flag would need clearing after each use,
/// and a clear that races the observation is a click that does nothing — the
/// same reset-shaped bug the Add Channel window had (see
/// `AddChannelWindow`'s `onAppear`). Every increment is a distinct value, so
/// two clicks in a row both land without anything having to be reset.
@MainActor
@Observable
final class WatchingReveal {

  /// One instance for the app. A second would be observed by nobody, since
  /// `QueueView` reads this one by name.
  static let shared = WatchingReveal()

  private(set) var requests = 0

  func request() { requests += 1 }
}
