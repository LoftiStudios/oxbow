import Foundation

/// Read-only sweep with injected fetch. Timing belongs to `WatchPollPolicy`; task ownership
/// belongs to `WatchPoller`. Never mark findings seen here: that would consume them before the
/// user acts.
public enum WatchPoll {

  /// Sweeps sequentially to limit traffic to the undocumented API. A channel's failure is
  /// captured in its own result and does not stop the others.
  public static func sweep(
    _ watches: [Watch],
    using fetch: @Sendable (String) async -> Result<[ChannelArchive], ChannelFeedError>)
    async -> [WatchPollResult]
  {
    var results: [WatchPollResult] = []
    results.reserveCapacity(watches.count)

    for watch in watches {
      let outcome: WatchPollResult.Outcome
      switch await fetch(watch.login) {
      case .success(let archives):
        // Return all archives so consumers can show downloaded history. Callers needing unseen
        // findings filter separately.
        outcome = .found(archives)
      case .failure(let error):
        outcome = .failed(error)
      }
      results.append(
        WatchPollResult(login: watch.login, displayName: watch.displayName, outcome: outcome))
    }
    return results
  }
}
