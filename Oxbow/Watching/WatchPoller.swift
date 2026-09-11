import Foundation
import Observation
import OxbowKit

/// Runs a sweep of the watched channels and republishes the results for
/// SwiftUI.
///
/// **Timing and wiring only.** When a sweep is due is `WatchPollPolicy`; what a
/// sweep produces is `WatchPoll.sweep`. Both are in `OxbowKit` and both are
/// tested without a window. What is left here is the `Task`, and it is here
/// because a `Task` is not a decision.
///
/// **Polls at launch and then on an interval while the app runs — no agent.**
/// `docs/design/channel-watching.md` §5.1 argues this from measurement: the
/// shortest archive-retention window observed was 43 days, so a Mac that is
/// awake occasionally still beats the deadline comfortably. A launch agent
/// would buy coverage for the user who does not open Oxbow for six weeks, and
/// would cost a second process contending for state `QueueEngine` will not
/// share.
@MainActor
@Observable
final class WatchPoller {

  /// The most recent sweep. Empty until the first one lands.
  ///
  /// The inbox is derived from this rather than accumulated
  /// (`docs/design/channel-watching.md` §4), so replacing it wholesale is
  /// correct: an archive that has expired since the last sweep simply stops
  /// appearing, which is what should happen to a row nothing can download.
  private(set) var results: [WatchPollResult] = []

  /// True while a sweep is in flight, so the UI can say so rather than looking
  /// idle for however long a handful of network round trips takes.
  private(set) var isSweeping = false

  private(set) var lastPolled: Date?

  /// Which watches were demoted to notify-only this sweep, keyed by login,
  /// for `WatchingView` to show.
  ///
  /// **Replaced wholesale every sweep, never accumulated.**
  /// `AutoDownloadPolicy.decide`'s own doc comment is explicit that demotion
  /// is per-call, not per-watch state: the next sweep re-asks the disk and
  /// the destination and gets whatever the world looks like *then*, so a
  /// drive that came back submits normally again with no recovery step. A
  /// dictionary merged forward instead of replaced would keep reporting a
  /// channel demoted after the disk freed up, which is indistinguishable
  /// from the checkbox having been turned off — exactly the confusion
  /// `docs/design/channel-watching.md` §6.2 rules out.
  private(set) var demotions: [String: AutoDownloadPolicy.Reason] = [:]

  /// Archive ids a person has already been told are waiting, carried between
  /// sweeps so the same rows are not re-announced every hour.
  ///
  /// Replaced wholesale by each `FindingAnnouncement.decide` — see that
  /// type's `Decision.announced` for why it is returned even when nothing is
  /// said, and its `decide` for why nothing persists this across launches.
  private var announced: Set<String> = []

  /// Why an archive the automatic path tried to queue did not reach the
  /// queue, keyed by archive id, for `WatchingView` to show on the row.
  ///
  /// **This used to be a `catch` with a comment in it.** `WatchPoller.submit`
  /// discarded every `IntentSubmission.Failure` it caught, so a channel whose
  /// archives were all being refused looked exactly like a channel with
  /// nothing new — no badge, no row state, no log line. `docs/design/
  /// channel-watching.md` §6.3 already says a failed automatic download has
  /// to come back as something a person can act on; a refusal *before* the
  /// job exists is the same promise, one step earlier.
  private(set) var submissionFailures: [String: String] = [:]

  private let store: WatchStore
  private let feed: ChannelFeed
  private let now: () -> Date
  private var loop: Task<Void, Never>?

  /// Where a sweep writes down what it saw. See `record(archives:forLogin:
  /// seenAt:into:)` — the write itself is a `static` function so it is
  /// testable without a poller; this is only where a live poller's copy of
  /// the store lives, mirroring `store` above.
  ///
  /// **What is single is the path, not the store.** A `VideoRecordStore` is a
  /// struct wrapping a `URL`, holds no state and caches nothing, so the app
  /// builds several — this one, `WatchingModel`'s, the one `QueueHost` hands
  /// `JobNotifier`, and `VideoRecording`'s — and they are safe against each
  /// other because every one of them does its load-modify-save on the main
  /// actor with no suspension point in between (`VideoRecorder`'s doc comment
  /// has that rule in full).
  ///
  /// The thing that must stay in one place is
  /// `AppComposition.videoRecordURL(supportDirectory:)`: every one of those
  /// stores is pointed at the file that function names, and none of them
  /// composes a path of its own. A call site that built its own path — even
  /// the identical one today — could drift away from the others with nothing
  /// to notice, and half of Oxbow would be writing a record the other half
  /// never reads.
  let videoRecordStore: VideoRecordStore

  /// Where a sweep's announcement goes. Injected so a test can read what
  /// would have been posted instead of posting it — the notification centre
  /// itself is unavailable under `xcodebuild test` anyway (see `JobNotifier
  /// .center`), which would make an un-injected default silently untestable
  /// rather than merely inconvenient.
  private let announce: (FindingAnnouncement.Message) -> Void

  /// Every collaborator is injected rather than built here so a preview can
  /// supply a fixed answer without a network or a support directory.
  ///
  /// `videoRecordStore` has no default, for the same reason `store` and
  /// `feed` do not: there is no value that is correct to fall back to. A
  /// call site that omitted it would still sweep and still download —
  /// nothing about the app would look broken — but every fact `record(
  /// archives:forLogin:seenAt:into:)` writes would vanish into whatever the
  /// default pointed at, silently, with no error and no failing test, until
  /// someone eventually noticed that expired videos had stopped rendering.
  /// That is precisely the failure this whole feature exists to prevent, so
  /// the parameter is required rather than defaulted.
  init(
    store: WatchStore, feed: ChannelFeed, videoRecordStore: VideoRecordStore,
    now: @escaping () -> Date = Date.init,
    announce: @escaping (FindingAnnouncement.Message) -> Void = { message in
      QueueHost.shared.notifyFindings(title: message.title, body: message.body)
    }
  ) {
    self.store = store
    self.feed = feed
    self.videoRecordStore = videoRecordStore
    self.now = now
    self.announce = announce
  }

  /// The live one, reading the watch file `AppComposition` sites and talking to
  /// Twitch over an ephemeral session.
  ///
  /// Ephemeral for the same reason `UpdateCheck`'s is: nothing here benefits
  /// from a URL cache, and a cached answer is precisely the wrong thing for a
  /// question whose whole purpose is "has anything changed".
  static func live(supportDirectory: URL) -> WatchPoller {
    let configuration = URLSessionConfiguration.ephemeral
    // `WatchPoll.sweep` is sequential, one request per watch, so a stalled
    // request here does not cost one channel's turn — it costs `isSweeping`
    // latched true, and every other watch queued behind it, for as long as
    // the default sixty-second timeout allows. `UpdateModel.live()` accepts
    // that default because it makes one request; twenty watches behind a
    // black-holed network would make this a twenty-minute "sweeping" state.
    configuration.timeoutIntervalForRequest = 15
    configuration.waitsForConnectivity = false
    let session = URLSession(configuration: configuration)
    let watchStore = WatchStore(
      fileURL: AppComposition.watchStoreURL(supportDirectory: supportDirectory))
    let videoRecordStore = VideoRecordStore(
      fileURL: AppComposition.videoRecordURL(supportDirectory: supportDirectory))
    // Run once per launch, against the store built two lines above rather
    // than one composed here from a path of its own — see `videoRecordStore`
    // for why the path is the thing kept single, and a second store value
    // over `AppComposition`'s path is not the problem.
    migrateSeenIfNeeded(watches: (try? watchStore.load()) ?? [], into: videoRecordStore)
    return WatchPoller(
      store: watchStore,
      feed: ChannelFeed(fetch: { request in
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
          throw ChannelFeedError.malformedPayload(snippet: "")
        }
        return (data, http)
      }),
      videoRecordStore: videoRecordStore)
  }

  /// Folds each watch's stored `seen` set into the record.
  ///
  /// **Safe to run on every launch**, which is why it has no "have I run
  /// already" flag to get wrong: `SeenMigration.migrate` never overwrites a
  /// state already recorded, so a second run is a no-op over real progress
  /// (`docs/design/channel-history.md` §3.2).
  ///
  /// `seen` is deliberately left on disk rather than cleared. It is small, it
  /// costs nothing, and leaving it means a bad migration is recoverable by
  /// deleting `videos.json` — a one-way trip that does not have to be pretty
  /// still benefits from being reversible while the feature is unshipped.
  static func migrateSeenIfNeeded(watches: [Watch], into store: VideoRecordStore) {
    guard let library = try? store.load() else { return }
    let migrated = SeenMigration.migrate(watches: watches, into: library)
    guard migrated != library else { return }
    try? store.save(migrated)
  }

  /// Sweeps once now, then every `WatchPollPolicy.interval` for as long as the
  /// app runs.
  ///
  /// Idempotent: calling it twice does not start a second loop. The queue
  /// window's `.task` may run more than once across a scene's lifetime, and two
  /// loops would double the traffic for no benefit.
  func start() {
    guard loop == nil else { return }
    loop = Task { [weak self] in
      while !Task.isCancelled {
        await self?.sweepIfDue()
        try? await Task.sleep(for: .seconds(WatchPollPolicy.interval))
      }
    }
  }

  func stop() {
    loop?.cancel()
    loop = nil
  }

  /// A `Task` outlives the object that started it unless something cancels
  /// it, so without this the hourly loop would keep waking for the life of
  /// the process even after this instance is gone.
  isolated deinit {
    loop?.cancel()
  }

  /// A person asked, so this bypasses `WatchPollPolicy`'s interval throttle
  /// for the same reason `UpdateModel`'s manual check does: pressing a button
  /// is an explicit request.
  ///
  /// It does **not** bypass `sweep`'s own `isSweeping` guard. If a sweep is
  /// already in flight this returns immediately without queuing behind it or
  /// awaiting its results, so a caller that reads `results` right after
  /// calling this may still see the previous sweep's answer. Nothing calls
  /// this yet; stage 2b, which will, should decide then whether to await an
  /// in-flight sweep instead — that is a behaviour change, not a comment fix.
  func refreshNow() async {
    await sweep()
  }

  private func sweepIfDue() async {
    guard WatchPollPolicy.shouldPoll(now: now(), lastPolled: lastPolled) else { return }
    await sweep()
  }

  private func sweep() async {
    guard !isSweeping else { return }

    // A watch file that cannot be *decoded* is not an empty watch list — but
    // `WatchStore.load` already sets that case aside and returns empty, so
    // there is nothing here to distinguish. What the `try?` still swallows is
    // narrower: a file that exists but whose `Data(contentsOf:)` read fails —
    // permissions changed underneath it, say — propagates out of `load()`
    // rather than being caught by its own `do`/`catch`, and lands here as the
    // same "nothing to report" as a genuinely empty list.
    //
    // Either way, `results` still gets cleared below rather than left as-is:
    // an empty list and an unreadable file both mean "nothing to report",
    // and neither is evidence that the archives found on the last successful
    // sweep are still there. Leaving stale rows behind because this sweep
    // couldn't ask would tell the user about downloads that may no longer
    // exist.
    let watches = (try? store.load()) ?? []

    // **Every sweep, not only launch.** Adding a channel with "Only new"
    // seeds its whole back catalogue into `Watch.seen` without recording a
    // state for any of it, and `AddChannelModel` has no record store to write
    // one with — its window deliberately carries no support directory. Folding
    // the seen-set in here catches that, and any other writer that marks seen
    // without recording why, which is what lets the display side stop reading
    // `seen` at all. Idempotent and short-circuiting when nothing changed, so
    // the ordinary sweep pays one comparison.
    Self.migrateSeenIfNeeded(watches: watches, into: videoRecordStore)

    guard !watches.isEmpty else {
      // `demotions` clears alongside `results` here rather than inside
      // `actOnFindings`: this early return is the only path that skips that
      // call, so a guard there would never run. Without this, demoting a
      // channel and then removing every watch would leave the dictionary
      // holding a stale demotion under that login — and re-adding the same
      // login later would show it as demoted before the next sweep ever
      // looks at it, the exact "checkbox looks off when it isn't" confusion
      // `docs/design/channel-watching.md` §6.2 rules out, arrived at through
      // the reset path instead of the decision path.
      results = []
      demotions = [:]
      // Cleared alongside them, for the reason the comment above gives about
      // `demotions`: every id this was holding belonged to a watch that is
      // now gone, and re-adding that login later must be able to announce
      // its findings afresh rather than find them already spoken for.
      announced = []
      submissionFailures = [:]
      return
    }

    isSweeping = true
    let swept = await WatchPoll.sweep(watches) { login in
      do {
        return .success(try await feed.archives(forLogin: login))
      } catch let error as ChannelFeedError {
        return .failure(error)
      } catch {
        // URLSession's own errors — offline, DNS, TLS. Reported as their own
        // case rather than squeezed into an existing one: `.server(status: 0)`
        // would render as "Twitch answered with status 0", which blames Twitch
        // for the user's wifi, and `.malformedPayload` would blame it for a
        // response that never arrived.
        return .failure(.unreachable(error.localizedDescription))
      }
    }
    results = swept
    // Explicitly `.found`, never the `archives` convenience getter: that
    // getter flattens `.failed` to an empty array, and its own doc comment
    // says it must never be the only signal a caller reads. Matching on
    // `.found` here makes "a failed sweep records nothing" a deliberate
    // statement rather than a coincidence of the flattening.
    //
    // **Nothing pins this match, because `record`'s empty guard covers for
    // it.** A failure's archives flatten to `[]`, so dropping this match
    // sends a failed channel into `record`, which returns on the empty array
    // before `seenAt` is ever considered — and every test stays green,
    // `failedSweepLeavesRecordUntouched` included. That makes the two guards
    // a pair with only one of them tested: `emptySweepIsNoOp` holds the other
    // end. The day `record` stops returning early on `[]` — a stamp written
    // outside the loop, say — this match is the only thing left between a
    // failed sweep and a sighting recorded for a channel Twitch was never
    // successfully asked about. Change either guard and check the other.
    for result in swept {
      guard case .found(let archives) = result.outcome else { continue }
      Self.record(
        archives: archives, forLogin: result.login,
        displayName: result.displayName, seenAt: now(), into: videoRecordStore)
    }
    lastPolled = now()
    let submitted = await actOnFindings(watches: watches, results: swept)

    // After `actOnFindings`, never before it: what that call submitted is
    // precisely what must *not* be announced as waiting, and it is only
    // known once it has run. `§2.2`'s banner is a pointer to the inbox, so
    // an archive already queued has nothing for it to point at.
    let decision = FindingAnnouncement.decide(
      results: swept, watches: watches, submitted: submitted, alreadyAnnounced: announced)
    announced = decision.announced
    if let message = decision.message { announce(message) }

    isSweeping = false
  }

  /// Acts on one sweep's findings: for each watch, asks `AutoDownloadPolicy`
  /// whether its automatic path may submit what it found, and either queues
  /// each archive through `IntentSubmission.submit` — the one composition
  /// path, per `Oxbow/Intents/DownloadTwitchVideoIntent.swift`'s own doc
  /// comment and `docs/design/automation.md` §4 — or records the demotion.
  ///
  /// **`watches` is the list `sweep()` loaded before the network round
  /// trips, not a fresh read.** "Frozen" here means *not read live off
  /// `Preferences`* — unlike the free-space floor, re-read fresh for every
  /// watch below — not that a watch's `downloadsAutomatically` and
  /// `settings` cannot change at all. They can: `AddChannelModel.add()` in
  /// edit mode rewrites both, live, through its own `WatchStore` on the same
  /// file, precisely so a person can edit a channel's destination or quality
  /// (`docs/design/channel-watching.md` §3.2). Deciding against this stale
  /// snapshot is fine either way — the next sweep re-decides from whatever
  /// is on disk *then*. What is narrower is `submit(_:from:into:)` below,
  /// which passes this same snapshot's settings into `IntentSubmission
  /// .submit` to **compose** the job, not merely to decide: an edit that
  /// lands while one of this sweep's archives is already in flight can
  /// queue that one archive under settings that were just superseded. Self-
  /// correcting next sweep, and not worth locking or coordinating around —
  /// see `markSubmitted(_:login:)` for the write-back hazard this same gap
  /// causes on the other side of the store.
  /// Returns the archive ids this sweep actually queued, for
  /// `FindingAnnouncement` to exclude — an archive that is downloading is not
  /// one waiting for a person, and `JobNotifier` reports it when it settles.
  /// Ids only, not the archives: the caller needs set membership, and
  /// returning the richer thing would invite a second use this cannot
  /// promise (a submission that succeeded may already have been superseded
  /// by an edit — see this function's note on frozen settings).
  @discardableResult
  private func actOnFindings(watches: [Watch], results: [WatchPollResult]) async -> Set<String> {
    // No empty-list guard here: `sweep()`'s own early return is the only
    // caller that could reach this with an empty `watches`, and that return
    // happens before this is ever called — clearing `demotions` there
    // instead (see `sweep()`) is what actually reaches the empty-list case.
    var submitted: Set<String> = []
    let floor = Preferences().freeSpaceFloor
    let resultsByLogin = Dictionary(uniqueKeysWithValues: results.map { ($0.login, $0) })

    // Resolved once, up front, rather than only right before submitting —
    // this sweep needs `controller.jobs` to decide what to offer (see
    // `excludingArchivesWithFailedJobs`, used in the loop below), not only
    // to act on that decision once it is made.
    //
    // Falls back to an empty job list rather than returning early when the
    // engine is not `.ready`: the floor and destination checks below owe
    // nothing to the queue being reachable, and bailing out here would drop
    // this sweep's demotions along with its submissions for a condition
    // that, in practice, `QueueHost` resolves once at launch and never
    // un-resolves.
    let readyState = await QueueHost.shared.ready()
    let controller: QueueController? = {
      guard case .ready(let controller) = readyState else { return nil }
      return controller
    }()

    var newDemotions: [String: AutoDownloadPolicy.Reason] = [:]
    var toSubmit: [(watch: Watch, archives: [ChannelArchive])] = []

    for watch in watches {
      // A failed fetch reads as no findings here, exactly the flattening
      // `WatchPollResult.archives`'s own doc comment says a *health* check
      // must not use — but this is not one. The floor and destination
      // checks below are unaffected by whether the feed answered, and a
      // watch with nothing found submits nothing regardless of why.
      //
      // Filtered against this watch's own `seen` here — see
      // `Self.unseenFindings` for why this, and not `WatchPoll.sweep`, is
      // where that guard has to live now.
      //
      // Filtered through `Self.excludingArchivesWithFailedJobs` before
      // `decide()` ever sees them — see that function's own doc comment for
      // why a `.failed` job has to remove its archive from the unattended
      // path entirely, not merely fail to duplicate it.
      let unseen = Self.unseenFindings(for: watch, resultsByLogin: resultsByLogin)
      let findings = Self.excludingArchivesWithFailedJobs(
        unseen, jobs: controller?.jobs ?? [])
      let destination = watch.settings.destination
      let destinationExists = FileManager.default.fileExists(atPath: destination.path)
      // An unreadable volume is treated as below the floor, not as
      // unlimited. `decide()` takes this figure on faith, and the failure
      // mode of guessing "plenty of room" is an unattended multi-gigabyte
      // download; the failure mode of guessing "none" is a channel sitting
      // notify-only until the next sweep re-probes. Only the second is
      // recoverable by doing nothing.
      let availableBytes = VolumeSpace.live.availableBytes(destination) ?? 0

      // Asked per watch, against only that channel's own jobs: a members-only
      // channel is a fact about one channel, and counting every failure in the
      // queue would let three restricted archives on one channel demote a
      // different one that is working fine.
      let mine = (controller?.jobs ?? []).filter { job in
        guard let media = job.mediaIdentifier else { return false }
        return resultsByLogin[watch.login]?.archives.contains { $0.id == media } ?? false
      }

      switch AutoDownloadPolicy.decide(
        watch: watch, findings: findings, availableBytes: availableBytes,
        destinationExists: destinationExists,
        contentRestricted: AutoDownloadPolicy.isContentRestricted(jobs: mine),
        floor: floor)
      {
      case .notAutomatic:
        continue
      case .demoted(let reason):
        newDemotions[watch.login] = reason
      case .submit(let archives):
        guard !archives.isEmpty else { continue }
        toSubmit.append((watch, archives))
      }
    }

    // Published as a whole, once, rather than as each watch is decided —
    // so a caller reading `demotions` mid-sweep never sees a partial one
    // that looks like the sweep already finished.
    demotions = newDemotions

    guard !toSubmit.isEmpty else { return submitted }

    // Resolved once, above — the same engine `DownloadTwitchVideoIntent
    // .perform()` binds once, for the same reason its own comment gives: a
    // second call was never wrong, only harder to read. `controller` is nil
    // exactly when the engine was not `.ready` up there, in which case there
    // is nothing to submit into regardless of what this sweep decided.
    guard let controller else { return submitted }

    // Sequential, matching `WatchPoll.sweep`'s own reasoning
    // (`docs/twitch-channel-api.md` §4): issuing a dozen submissions at once
    // is the traffic shape that document warns about, and `QueueEngine`
    // serialises the actual downloads anyway, so concurrency here would only
    // buy a burst of requests with nothing to show for it.
    var newFailures: [String: String] = [:]
    for (watch, archives) in toSubmit {
      let result = await ArchiveSubmission.submit(archives, for: watch, into: controller)
      for archive in result.queued {
        submitted.insert(archive.id)
        markSubmitted(archive.id, login: watch.login)
      }
      newFailures.merge(result.failures) { current, _ in current }
    }

    // Replaced wholesale, like `demotions` and for the same reason: a
    // refusal is re-decided from scratch every sweep, so one that has
    // stopped happening must stop being shown.
    submissionFailures = newFailures
    return submitted
  }

  /// `findings` with any archive removed whose `mediaIdentifier` already has
  /// a `.failed` job in `jobs` — the fix for a durably failing archive being
  /// re-downloaded automatically, every sweep, for its entire retention
  /// window.
  ///
  /// **The loop this closes.** `AutoDownloadObserver.forget` un-marks a
  /// failed automatic download's archive from `seen` so a *person* can
  /// retry it (§6.3) — but the very next sweep loads that watch fresh, sees
  /// the archive as unseen again, and — automatic still being on —
  /// resubmits it unattended. `IntentSubmission.submit`'s duplicate guard
  /// only blocks *unfinished* jobs (`JobStatus.isUnfinished`), so the
  /// finished `.failed` job blocks nothing there. It fails the same way,
  /// `forget` un-marks it again, and the cycle repeats: one full download
  /// attempt per poll interval, forever, each one leaving behind a fresh
  /// retained resume directory keyed on that attempt's own `JobID`
  /// (`resume.md` §8 reclaims none of them without a person dismissing).
  /// `docs/design/channel-watching.md` §6.3 rules this out in as many words.
  ///
  /// **The same move Task 4 used for the relaunch hazard, applied here
  /// instead of adding state.** `AutoDownloadObserver.baseline`'s own doc
  /// comment picks the snapshot already in hand over a fourth persisted
  /// "already handled" record; this does the same thing one level up —
  /// `WatchPoller` already holds `controller.jobs` for every sweep, so
  /// checking it for a `.failed` sibling costs nothing new to store. The
  /// archive still shows in the inbox — `Watch.findings(in:)` is untouched,
  /// and `seen` is never written here — so a person can still Add it
  /// deliberately; this only removes it from the path nobody is watching.
  ///
  /// **A `.cancelled` job does not count**, for the identical reason
  /// `AutoDownloadObserver.mediaIdentifiersAlreadyAnswered` excludes it: a
  /// cancellation is a person saying no, not the app having tried and lost,
  /// so it must not block a future unattended attempt the way a real
  /// failure does.
  ///
  /// A `static` pure function, deliberately, rather than inlined in
  /// `actOnFindings` — the same reason `AutoDownloadPolicy.decide` (the
  /// sibling decision this filters findings before ever reaching) takes no
  /// collaborators of its own: it is testable against plain `Job` and
  /// `ChannelArchive` fixtures, with no store, no clock and no `QueueHost`.
  /// `nonisolated` for the identical reason — it touches no property of
  /// this `@MainActor` class, so a test can call it directly rather than
  /// hopping actors to reach a function that never needed the hop.
  nonisolated static func excludingArchivesWithFailedJobs(
    _ findings: [ChannelArchive], jobs: [Job]
  ) -> [ChannelArchive] {
    let failedMediaIdentifiers = Set(
      jobs.compactMap { $0.status == .failed ? $0.mediaIdentifier : nil })
    return findings.filter { !failedMediaIdentifiers.contains($0.id) }
  }

  /// `watch`'s share of `resultsByLogin`, filtered down to what it has not
  /// already seen.
  ///
  /// **This is the guard, not a convenience.** `WatchPoll.sweep` used to be
  /// the one filtering `seen` out before anything downstream ever saw a
  /// result; it no longer does (`WatchPoll.swift`'s own comment on `.found`
  /// says why), which makes this the only thing standing between the
  /// unattended path and re-downloading every archive a person has ever
  /// completed (`docs/design/channel-watching.md` §4). A single inline
  /// expression carrying that much weight, with nothing exercising it
  /// directly, is exactly the shape `excludingArchivesWithFailedJobs` beside
  /// it was already pulled out to avoid — so this gets the same treatment:
  /// `nonisolated static`, testable against plain `Watch` and
  /// `WatchPollResult` fixtures, no `store` or actor hop required.
  ///
  /// A login absent from `resultsByLogin` — a channel this sweep did not
  /// cover — reads as no findings, not as "everything": there is nothing to
  /// invent an answer from, so the empty case here matches the failed-fetch
  /// case a few lines above it in `actOnFindings`.
  nonisolated static func unseenFindings(
    for watch: Watch, resultsByLogin: [String: WatchPollResult]
  ) -> [ChannelArchive] {
    watch.findings(in: resultsByLogin[watch.login]?.archives ?? [])
  }

  /// Marks `archiveID` seen for `login`, so `Watch.findings(in:)` never
  /// offers it again — and so a later failure (a future stage's concern,
  /// once a submitted job can be watched to a terminal status) has an
  /// entry in `seen` to remove via `Watch.forgetting(_:)`.
  ///
  /// **Re-reads the store immediately before writing, rather than reusing
  /// `watches` from the top of `sweep()`.** This is the same hazard
  /// `AddChannelModel.add()`'s own doc comment names: `IntentSubmission
  /// .submit` awaits a metadata fetch before this ever runs, and across
  /// that suspension the Watching pane's own writers — `WatchingModel
  /// .markSeen`, `stopWatching` — can and do run. Writing back the copy
  /// loaded before the sweep's network round trips would silently overwrite
  /// whatever any of those wrote in the meantime; loading fresh here makes
  /// this write land on top of whatever is actually on disk, the same
  /// discipline `WatchingModel.markSeen` already keeps for its own writes.
  ///
  /// Best effort, like every other writer's use of this store: nothing here
  /// has a surface to show a person a save failure mid-sweep. A lost mark
  /// costs one re-offer next sweep only while the job it was for is still
  /// unfinished — `IntentSubmission.submit`'s duplicate guard tests
  /// `status.isUnfinished`, so a re-offer against a job still in the queue
  /// is caught there and folds back into `.alreadyQueued`. If the job has
  /// already finished by the next sweep and the mark never landed, that
  /// guard has nothing to catch: the archive looks unseen again and gets
  /// downloaded a second time, the exact outcome `seen` exists to prevent
  /// (§4). Surfacing the I/O error mid-sweep would be worse than this
  /// narrow, rare window, so the write stays best-effort — this comment
  /// just stops promising it is free.
  private func markSubmitted(_ archiveID: String, login: String) {
    guard var current = try? store.load() else { return }
    guard let index = current.firstIndex(where: { $0.login == login }) else { return }
    current[index] = current[index].marking([archiveID])
    try? store.save(current)
  }

  /// Records the facts a sweep learned about every archive it saw.
  ///
  /// **Every archive, not just the unseen ones.** The record is what makes an
  /// expired video still render, and an archive already downloaded is exactly
  /// the one worth keeping — filtering here would repeat the shape of the bug
  /// that made `WatchPoll.sweep` return `findings(in:)` and erased completed
  /// downloads before any consumer saw them.
  ///
  /// **Best effort, like every other writer's use of a store here.** Nothing
  /// in a sweep has a surface to show a person a save failure, and a lost write
  /// costs a row some fields until the next sweep — never a download.
  ///
  /// `static` and taking its store as a parameter so it is testable without
  /// standing up a poller.
  static func record(
    archives: [ChannelArchive],
    forLogin login: String,
    displayName: String?,
    seenAt: Date,
    into store: VideoRecordStore)
  {
    // **The second of two guards against recording a failure, and it is the
    // one carrying both.** `sweep()`'s `case .found` match above is the first
    // — but a failure's archives flatten to `[]`, so this line stops one even
    // when that match is gone. `emptySweepIsNoOp` pins this guard directly;
    // nothing pins that match, precisely because this guard covers for it.
    // So relaxing this one does more than let an empty save through: it makes
    // that match load-bearing and untested at the same moment. Change either
    // guard and check the other.
    guard !archives.isEmpty else { return }
    guard var library = try? store.load() else { return }

    for archive in archives {
      library.record(VideoRecord(
        id: archive.id,
        login: login,
        displayName: displayName,
        title: archive.title,
        durationSeconds: Int(archive.duration.components.seconds),
        publishedAt: archive.publishedAt,
        categoryName: archive.categoryName,
        thumbnailURLs: [archive.thumbnailURL].compactMap { $0 },
        lastSeenOnTwitch: seenAt))
    }

    try? store.save(library)
  }
}
