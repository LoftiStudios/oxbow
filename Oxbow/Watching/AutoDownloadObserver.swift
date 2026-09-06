import Foundation
import OxbowKit

/// Returns a failed automatic download to the inbox.
///
/// `docs/design/channel-watching.md` §6.3: `Watch.seen` marks an archive the
/// moment it is submitted, so a failed automatic download would otherwise be
/// **permanent** — the watch never looks at that archive again, and it
/// expires within weeks. This is the fix: un-mark the archive with
/// `Watch.forgetting(_:)` so it reappears as an ordinary finding, marked as
/// failed, for a person to Add (or not) through the intake window like any
/// other finding.
///
/// **Not an automatic retry.** A VOD that fails for a durable reason —
/// subscriber-only, region-locked, removed mid-download — fails identically
/// every time, so this never re-submits anything itself. See §6.3 and
/// `resume.md` §8, which deferred auto-retry deliberately.
///
/// **A cancelled job is not a failure, and this does nothing for one.**
/// `JobStatus` treats `.failed` and `.cancelled` alike as finished, but they
/// mean opposite things here: a failure is the app not managing something, a
/// cancellation is a person saying no. Re-offering something the user just
/// cancelled would be the app arguing with them.
///
/// **Deliberately broader than "automatic."** This un-marks a failed job's
/// `mediaIdentifier` out of *any* watch's `seen` set, including one a person
/// Added manually from the inbox rather than one the automatic path
/// submitted. §6.3's letter says "automatic", but distinguishing the two
/// would need a persisted record of which submissions were automatic — more
/// state, on the feature `Watch.forgetting`'s own doc comment says has
/// already been bitten by exactly that shape of bookkeeping. The behaviour
/// is right either way: a manual Add that failed is equally worth
/// re-offering, and there is no second rule to keep in sync with the first.
///
/// **Touches nothing about the job itself.** The failed job keeps its row
/// and its retained bytes; reclaiming them stays a person's decision exactly
/// as `resume.md` §8 specifies. This adds a way to notice, not a new policy
/// about disk.
@MainActor
final class AutoDownloadObserver {
  private let store: WatchStore

  /// The status this observer last saw for each job, so it can tell a fresh
  /// failure from one it has already acted on.
  ///
  /// **Fires on the transition into `.failed`, not on every snapshot that
  /// carries one.** `QueueController.onSnapshot` publishes continuously, and
  /// a failed job sits `.failed` in every snapshot from the moment it fails
  /// until it is removed or retried — so acting on every snapshot would
  /// un-mark the same archive dozens of times for one real failure.
  /// Un-marking twice is harmless today (`Watch.forgetting` just subtracts a
  /// value that may already be absent), but nothing here should depend on
  /// that being true forever: a design that relies on idempotence to stay
  /// correct is one that breaks the day something downstream stops being
  /// idempotent. This tracks the last status seen per job — the same idiom
  /// `NotificationDecision` uses for the identical reason — and only acts
  /// when a job's status has just *become* `.failed`.
  ///
  /// **Deliberately does not seed silently the way `NotificationDecision`
  /// does.** That type treats a job absent from its baseline as a job that
  /// must not fire, so a launch that reconciles an already-failed job from
  /// an interrupted previous run notifies about nothing — reasonable there,
  /// because a missed notification about an old failure is merely stale.
  /// Here it would be wrong: `QueueHost` attaches its status observers
  /// before `start()` precisely so they see the first *reconciled* snapshot,
  /// and a job a crash left `.failed` before anything ever un-marked it must
  /// still be returned to the inbox on the very first snapshot this
  /// observer sees — silently skipping it would be exactly the archive loss
  /// §6.3 exists to prevent. So a job's absence from this baseline reads as
  /// "previously unfinished," which forces a job already `.failed` at first
  /// sight to be acted on rather than seeded past.
  ///
  /// **That same rule would double-fire across a relaunch, so `apply(_:)`
  /// checks the snapshot itself rather than adding more persisted state.**
  /// Sequence: job A fails and un-marks archive `12345`; a person re-Adds
  /// it, creating job B which marks `12345` seen again; A is deliberately
  /// left untouched (requirement 6) and sits `.failed`, user-cleared per
  /// `resume.md` §8, possibly for a long time; the app quits and relaunches
  /// before A is dismissed. The new observer's `baseline` starts empty, so
  /// A reads as freshly failed on the first snapshot — exactly the rule
  /// above requires — and would un-mark `12345` a second time even though B
  /// already answered it. Adding a persisted "already handled" record would
  /// fix this at the cost of the exact bookkeeping `Watch.forgetting`'s own
  /// doc comment says has already burned this feature once. The snapshot
  /// already carries the answer for free: before un-marking a newly-failed
  /// job's media, `apply(_:)` looks for another job *in that same snapshot*
  /// for the same `mediaIdentifier` that is `.done`, `.queued`, or
  /// `.running` — a success or a retry already in flight — and skips
  /// un-marking when one exists, because the failure has already been
  /// answered. A `.cancelled` sibling does not count: per the type's own
  /// doc comment above, a cancellation is a person saying no, not the app
  /// doing better, so it never blocks the un-mark.
  private var baseline: [JobID: JobStatus] = [:]

  init(store: WatchStore) {
    self.store = store
  }

  /// Feed every snapshot `QueueController.onSnapshot` publishes — the same
  /// call `JobNotifier.apply(_:)` receives. See `QueueHost
  /// .attachStatusObservers` for why this shares that one subscription
  /// rather than opening a second over the same engine.
  func apply(_ jobs: [Job]) {
    let newlyFailed = jobs.compactMap { job -> String? in
      // Absent from `baseline` reads as "was previously unfinished" — see
      // that property's own doc comment for why that, not silent seeding,
      // is the correct default here.
      let was = baseline[job.id] ?? .queued
      guard was != job.status, job.status == .failed else { return nil }
      return job.mediaIdentifier
    }
    baseline = NotificationDecision.statuses(of: jobs)

    guard !newlyFailed.isEmpty else { return }
    let answered = mediaIdentifiersAlreadyAnswered(in: jobs)
    let toForget = newlyFailed.filter { !answered.contains($0) }
    guard !toForget.isEmpty else { return }
    forget(toForget)
  }

  /// Media identifiers this same snapshot already has a better outcome for
  /// than the failure being considered — see `baseline`'s doc comment for
  /// the relaunch hazard this exists to close.
  ///
  /// `.done` means a retry already succeeded; `.queued` or `.running` means
  /// one is already in flight. Either way, un-marking now would be wrong:
  /// it would either put an archive back in the inbox that is already
  /// sitting on disk, or race a retry that is still working. `.failed` and
  /// `.cancelled` jobs are excluded on purpose — a second failure is not an
  /// answer to the first, and per this type's own doc comment a
  /// cancellation is a person saying no, not the app doing better, so
  /// neither should block the un-mark.
  private func mediaIdentifiersAlreadyAnswered(in jobs: [Job]) -> Set<String> {
    Set(jobs.compactMap { job -> String? in
      switch job.status {
      case .done, .queued, .running: return job.mediaIdentifier
      case .failed, .cancelled: return nil
      }
    })
  }

  /// Un-marks every watch whose `seen` set contains one of
  /// `mediaIdentifiers`.
  ///
  /// **Re-reads the store immediately before writing, rather than closing
  /// over a copy taken earlier.** This runs from a snapshot callback that
  /// can fire at any point relative to every other writer of `watches.json`
  /// — `WatchingModel.markSeen`, `AddChannelModel.add()` and `WatchPoller
  /// .markSubmitted` all guard the identical hazard on this same file, for
  /// the identical reason: writing back a copy loaded earlier would
  /// silently discard whatever any of those wrote in between. There is no
  /// snapshot of the watch list held anywhere on this type for exactly that
  /// reason — `store.load()` is only ever called right here, immediately
  /// before the save it feeds.
  ///
  /// **Refuses rather than overwrites when the store cannot be read.**
  /// `WatchStore.load()` throws only when the file exists but a genuine I/O
  /// failure prevented reading it — every decode failure it can hit is
  /// already recovered internally by moving the file aside. A throw here
  /// means there are watches on disk this call could not see, so writing
  /// back anyway would take every one of them down with a partial list.
  ///
  /// Best effort otherwise, matching `WatchPoller.markSubmitted`: this runs
  /// from a queue callback with no window to report a save failure to. A
  /// lost write here is worse than that one's — `baseline` is already
  /// updated in `apply(_:)` before this runs, so a save that fails is not
  /// retried on the next snapshot; the archive stays wrongly marked seen
  /// until something else changes it. Surfacing the I/O error mid-callback
  /// would need a window that does not exist at this call site, so the
  /// write stays best-effort — this comment just stops promising it is
  /// free.
  private func forget(_ mediaIdentifiers: [String]) {
    guard let current = try? store.load() else { return }
    try? store.save(current.map { $0.forgetting(mediaIdentifiers) })
  }
}
