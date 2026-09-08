import Foundation

/// What, if anything, a sweep should tell the user it found — as one pure
/// decision. This is `docs/design/channel-watching.md` §2.2's notification,
/// which that section is careful to call a pointer rather than the product:
/// the durable list is what a finding actually lands in, and this only says
/// how many are waiting and gets you there.
///
/// Takes no notification centre and no clock, in the shape
/// `AutoDownloadPolicy` and `WatchPollPolicy` already use for the sweep's
/// other two decisions — every argument is resolved by the caller, so every
/// rule here is decidable and testable without a window.
public enum FindingAnnouncement {

  /// The two strings a banner needs. Separate from the decision itself so
  /// that "say nothing" is a `nil` message rather than an empty title, which
  /// a caller could post by mistake.
  public struct Message: Equatable, Sendable {
    public let title: String
    public let body: String
  }

  /// One sweep's answer: what to say, and what the caller must carry into the
  /// next sweep.
  ///
  /// **`announced` is returned even when `message` is nil, and replaces the
  /// caller's set wholesale rather than merging into it.** Both halves matter.
  /// Returning it unconditionally is what prunes ids that have stopped
  /// appearing; replacing rather than merging is what keeps the set from
  /// growing for the life of the process.
  public struct Decision: Equatable, Sendable {
    public let message: Message?
    public let announced: Set<String>
  }

  /// Decides what one sweep should announce.
  ///
  /// - Parameters:
  ///   - results: the sweep, exactly as `WatchPoll.sweep` returned it —
  ///     everything the channel has, seen or not. A failed fetch contributes
  ///     nothing: `WatchPollResult.archives` flattens it to no archives,
  ///     which is the right reading *here* even though §7 forbids that
  ///     flattening as a health signal — a channel Twitch would not answer
  ///     for has nothing to announce, and the error itself belongs on the
  ///     row in `WatchingView`, not in a banner.
  ///   - watches: filters each result against its own watch's `seen`, rather
  ///     than trusting `results` to already be unseen-only. `WatchPoll.sweep`
  ///     used to do that filtering; a consumer that depended on a producer
  ///     several layers away continuing to filter broke silently the day the
  ///     producer changed — which is exactly what happened to the Watching
  ///     pane, and why the sweep no longer filters at all and every consumer
  ///     that wants unseen-only does this for itself.
  ///   - submitted: ids this sweep queued through the automatic path. They
  ///     are not waiting for anybody, and `JobNotifier` will report each job
  ///     when it settles; announcing them here would be both a duplicate and
  ///     a lie about who has to act.
  ///   - alreadyAnnounced: what the previous call returned as `announced`.
  ///
  /// **Why a remembered set rather than "are there findings".** A finding
  /// stays in the inbox until it is added or ignored (§2.2), and every sweep
  /// re-reports it, so announcing whenever findings exist would re-announce
  /// the same rows every hour for as long as they sat there — turning the one
  /// notification this feature gets into something a person learns to
  /// dismiss.
  ///
  /// **The set is per-process, and nothing persists it, deliberately.** A
  /// relaunch re-announces what is still waiting, which reads as correct
  /// rather than as a nag: those archives *are* still waiting, and the app
  /// has just started, so a person who left them unacted on is being told
  /// once more, not repeatedly. Persisting it would be a fourth piece of
  /// per-archive state alongside `seen`, `dismissed` and `demotions` —
  /// exactly the shape `Watch.forgetting(_:)`'s own comment records this
  /// feature being bitten by, and bought here for nothing better than
  /// suppressing one banner per launch.
  public static func decide(
    results: [WatchPollResult],
    watches: [Watch],
    submitted: Set<String>,
    alreadyAnnounced: Set<String>
  ) -> Decision {
    let byLogin = Dictionary(watches.map { ($0.login, $0) }, uniquingKeysWith: { first, _ in first })

    // Grouped by channel rather than flattened, because the title needs to
    // know whether everything new came from one channel (name it) or several
    // (count them) — a flat list of ids cannot answer that.
    let waiting = results.compactMap { result -> (displayName: String, archives: [ChannelArchive])? in
      // No matching watch means the channel was stopped while this sweep was
      // in flight. Skipped rather than passed through: failing open here
      // would announce a whole backlog for a channel nobody is watching any
      // more, for exactly the same reason `AutoDownloadPolicy` refuses to
      // guess in the automatic path's favour.
      guard let watch = byLogin[result.login] else { return nil }
      return (result.displayName,
              watch.findings(in: result.archives).filter { !submitted.contains($0.id) })
    }

    let waitingIDs = Set(waiting.flatMap { $0.archives.map(\.id) })
    let fresh = waiting
      .map { ($0.displayName, $0.archives.filter { !alreadyAnnounced.contains($0.id) }) }
      .filter { !$0.1.isEmpty }

    let announced = waitingIDs

    let freshCount = fresh.reduce(0) { $0 + $1.1.count }
    guard freshCount > 0 else { return Decision(message: nil, announced: announced) }

    let title = if fresh.count == 1 {
      freshCount == 1
        ? "New archive from \(fresh[0].0)"
        : "\(freshCount) new archives from \(fresh[0].0)"
    } else {
      "\(freshCount) new archives from \(fresh.count) channels"
    }

    let body = waitingIDs.count == 1
      ? "1 archive is waiting in Watching."
      : "\(waitingIDs.count) archives are waiting in Watching."

    return Decision(message: Message(title: title, body: body), announced: announced)
  }
}
