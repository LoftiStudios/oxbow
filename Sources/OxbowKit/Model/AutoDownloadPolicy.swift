import Foundation

/// Whether a watch's unattended path may submit its findings, as one pure
/// decision. This is `docs/design/channel-watching.md` §5.2's unattended half
/// and §6.2 in full, expressed as code rather than prose.
///
/// Takes no store, no network and no clock — every argument is already
/// resolved by the caller, which is what makes every rule here decidable
/// without a window and testable without one either. `WatchPollPolicy` is
/// the sibling that answers the adjacent "is a sweep due" question in the
/// same shape.
public enum AutoDownloadPolicy {

  /// What a sweep should do with one watch's findings.
  ///
  /// Three cases, not two, because `.submit([])` and `.notAutomatic` mean
  /// different things a caller must not conflate: the first is "automatic
  /// downloading ran and found nothing new," the second is "automatic
  /// downloading did not run." Collapsing them would make a checkbox that is
  /// off indistinguishable from a channel that is quiet.
  public enum Decision: Equatable, Sendable {
    case submit([ChannelArchive])
    case demoted(Reason)
    case notAutomatic
  }

  /// Why a watch's automatic downloading was demoted to notify-only this
  /// sweep. Each case carries what a person needs to be told, not just that
  /// something went wrong.
  public enum Reason: Equatable, Sendable {
    /// - `needed`: what the next archive would cost, so the sentence can say
    ///   what was actually being asked for. Without it the reserve is the
    ///   only number on screen, and a 250 GB reserve beside four short 360p
    ///   videos reads as a claim that those videos need 250 GB.
    case belowFloor(needed: Int64, available: Int64, floor: Int64)
    case destinationUnreachable(String)

    /// The sentence a finding or a settings row shows for this reason.
    public var sentence: String {
      switch self {
      case .belowFloor(let needed, let available, let floor):
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        let neededText = formatter.string(fromByteCount: needed)
        let availableText = formatter.string(fromByteCount: available)
        let floorText = formatter.string(fromByteCount: floor)
        // All three numbers, in the order a person needs them: what it
        // wanted, what there is, and what Oxbow will not spend. The reserve
        // alone was actively misleading — it is not a cost, and printed
        // beside a short video it looked like one.
        return "The next archive needs about \(neededText). Only "
          + "\(availableText) is free and Oxbow keeps \(floorText) in "
          + "reserve — downloads paused for this channel until there is "
          + "more room."
      case .destinationUnreachable(let path):
        return "\(path) is not available — downloads paused for this channel "
          + "until the destination is reachable again."
      }
    }
  }

  /// Decides what a watch's unattended sweep should do with what it found.
  ///
  /// - Parameters:
  ///   - watch: The watch being swept, for its `downloadsAutomatically` flag.
  ///   - findings: Archives this sweep found that the watch has not acted on
  ///     yet (`Watch.findings(in:)`), in any order.
  ///   - availableBytes: Free space on **the destination's own volume**,
  ///     already resolved by the caller — not the boot volume's. A channel
  ///     writing to `/Volumes/Archive` is asking whether *that* disk has
  ///     room, per §6.2; passing the wrong volume's figure here silently
  ///     answers the wrong question and this function has no way to catch it.
  ///   - destinationExists: Whether `watch.settings.destination` currently
  ///     resolves to something on disk, already checked by the caller.
  ///   - floor: The free-space floor to check `availableBytes` against —
  ///     `Preferences.freeSpaceFloor` in production, passed in rather than
  ///     read here so this stays clockless and storeless.
  /// - Returns: `.notAutomatic` if the watch has automatic downloading off;
  ///   otherwise `.demoted` if the destination is unreachable or the volume
  ///   is at or below the floor; otherwise `.submit` of a *prefix* of the
  ///   findings that are safe to queue unattended — see the batch-bound
  ///   paragraph below for why this is not necessarily all of them.
  ///
  /// **Demotion here is per-call, not per-watch state.** Nothing is
  /// recorded anywhere — the next sweep calls this again with whatever the
  /// world looks like *then*, so a drive that was unplugged and is now back
  /// submits normally again with no recovery step required. A demotion that
  /// stuck would be indistinguishable from the user having turned the
  /// checkbox off, which is exactly the confusion §6.2 rules out.
  ///
  /// **The floor gates submission once per call; it does not by itself gate
  /// how much that one call submits.** Checking `availableBytes` against
  /// `floor` above answers "may this sweep submit anything at all" — it says
  /// nothing about *how many* findings are safe to hand back, and returning
  /// every downloadable finding regardless of their combined size turns one
  /// sweep into an unbounded write against whatever margin the floor left.
  /// With 60 GB free and the 49 GB factory floor, a single sweep over a
  /// freshly backfilled "All available" watch could submit a hundred
  /// archives and run the disk to zero before the next sweep ever gets a
  /// chance to notice. So this walks `findings` in the order given and prices
  /// the running prefix with `BackfillEstimate` — the same arithmetic
  /// `docs/design/channel-watching.md` §3.3 already uses to price a backfill
  /// before a person commits to it, not a second estimator invented for this
  /// narrower case — stopping the moment adding one more finding would leave
  /// the volume below `floor`. Findings past that point are not refused or
  /// skipped, only left for a later sweep: they remain ordinary findings in
  /// the inbox, and once space frees up on this volume — a person deleting
  /// something, most likely — a later sweep picks up wherever this one
  /// stopped.
  public static func decide(
    watch: Watch, findings: [ChannelArchive], availableBytes: Int64,
    destinationExists: Bool, floor: Int64
  ) -> Decision {
    guard watch.downloadsAutomatically else { return .notAutomatic }

    // Destination first: it is the more specific, more actionable fact when
    // both apply (§6.2's account of the two causes converging on one
    // behaviour), and a missing destination makes the floor unanswerable
    // anyway — there is no volume to have asked about.
    guard destinationExists else {
      return .demoted(.destinationUnreachable(watch.settings.destinationPath))
    }
    // §5.2: a RECORDING broadcast is the newest item and exactly what a poll
    // finds first; it is skipped here and picked up once it has ended.
    let downloadable = findings.filter(\.isDownloadable)

    // Grows one finding at a time rather than pricing the whole set once and
    // dividing it back down: `BackfillEstimate`'s peak-overhead term is not
    // linear in the archive count (see its own doc comment), so the cost of
    // the first three findings cannot be read off the cost of all ten. This
    // is at most a few dozen `BackfillEstimate` calls over a page capped at
    // 100 (§7) — arithmetic, not I/O — so paying for correctness here rather
    // than approximating is free.
    var accepted: [ChannelArchive] = []
    for finding in downloadable {
      let candidate = accepted + [finding]
      let cost = BackfillEstimate(
        archives: candidate, cap: watch.settings.qualityCap, output: watch.settings.output
      ).bytes
      guard availableBytes - cost >= floor else { break }
      accepted = candidate
    }

    // **One rule, not two.** There used to be an absolute gate above this
    // loop — refuse outright whenever free space was under the floor —
    // which made a 300 MB download refusable on exactly the same terms as a
    // 500 GB one. The loop below it already expressed the rule properly:
    // a download may not take the volume below the reserve. The gate was
    // the same idea stated worse, and it fired first, so the better rule
    // never got a chance to allow anything.
    //
    // Nothing fitting is still a demotion, not a quiet `.submit([])`: those
    // two mean different things (see `Decision`), and a channel that cannot
    // spend a byte has to say so rather than look like a channel with
    // nothing new. Priced from the first finding alone, because that is the
    // one that did not fit — `accepted` is a prefix, so the loop stopped at
    // it.
    if accepted.isEmpty, let next = downloadable.first {
      let needed = BackfillEstimate(
        archives: [next], cap: watch.settings.qualityCap, output: watch.settings.output
      ).bytes
      return .demoted(.belowFloor(needed: needed, available: availableBytes, floor: floor))
    }

    // A partial fit still submits what fits and says nothing about the rest.
    // They stay ordinary findings and a later sweep picks them up, which is
    // this function's documented behaviour above — but nothing yet tells a
    // person *why* six of ten went. Worth fixing; it needs `Decision` to
    // carry the deferred ones, which is a wider change than this.
    return .submit(accepted)
  }
}
