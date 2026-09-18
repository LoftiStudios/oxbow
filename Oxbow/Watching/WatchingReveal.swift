import Observation

/// Bridge notification callbacks to Watching selection outside the view hierarchy. A
/// monotonically changing counter delivers repeated clicks without a reset race.
@MainActor
@Observable
final class WatchingReveal {

  static let shared = WatchingReveal()

  private(set) var requests = 0

  func request() { requests += 1 }
}
