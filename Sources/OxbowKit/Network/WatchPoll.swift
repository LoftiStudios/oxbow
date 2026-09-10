import Foundation

/// One sweep across the watched channels.
///
/// **Pure of timing and of the network.** `WatchPollPolicy` decides *when*, the
/// app target's `WatchPoller` owns the `Task`, and the fetch arrives as a
/// closure — so everything this type decides is testable without either.
///
/// **Read-only, deliberately.** A sweep writes nothing: the seen-set changes
/// only when a person Adds or Ignores a finding
/// (`docs/design/channel-watching.md` §2.2, §4). A poll that marked what it
/// found as seen would consume the finding before anyone saw it, and would put
/// the poller and the UI in a write race over `watches.json` for no gain.
public enum WatchPoll {

  /// Sweeps every watch, in order, and reports what each produced.
  ///
  /// **Sequential, not concurrent.** A handful of channels against an
  /// undocumented API is not worth parallelising, and issuing every request at
  /// once is exactly the traffic shape that attracts the attention
  /// `docs/twitch-channel-api.md` §4 is a warning about.
  ///
  /// One channel's failure never stops another's: each is caught into its own
  /// result, so a deleted channel or a drifted payload costs that watch and
  /// nothing else.
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
        // **Everything, not just what is unseen.** This used to return
        // `watch.findings(in: archives)`, which deleted every archive the
        // watch had acted on before any consumer saw it — and everything
        // that downloads an archive writes `seen`, so a completed download
        // was erased from the data and the Watching pane could never render
        // it as downloaded. The three callers that want findings-only apply
        // `Watch.findings(in:)` themselves: `WatchPoller.unseenFindings` for
        // the unattended-download path and `FindingAnnouncement.decide` for
        // the notification, plus `WatchingModel.rebuild` for what a person
        // sees — the last of those is also the only one of the three still
        // filtering for display, which is what lets `WatchingModel` call
        // itself the only place that filter is applied. It is
        // `findings(in:)`'s own doc comment, not this one, that is the right
        // place for why the filter still does not consider `isDownloadable`:
        // §5.2 forbids unattended queueing of a live broadcast, not showing
        // one to a person, and that reasoning belongs to the unattended and
        // notification paths, not to `WatchingModel`.
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
