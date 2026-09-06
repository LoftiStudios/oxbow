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

  private let store: WatchStore
  private let feed: ChannelFeed
  private let now: () -> Date
  private var loop: Task<Void, Never>?

  /// Both collaborators are injected rather than built here so a preview can
  /// supply a fixed answer without a network or a support directory.
  init(store: WatchStore, feed: ChannelFeed, now: @escaping () -> Date = Date.init) {
    self.store = store
    self.feed = feed
    self.now = now
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
    return WatchPoller(
      store: WatchStore(fileURL: AppComposition.watchStoreURL(supportDirectory: supportDirectory)),
      feed: ChannelFeed(fetch: { request in
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
          throw ChannelFeedError.malformedPayload(snippet: "")
        }
        return (data, http)
      }))
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
    lastPolled = now()
    await actOnFindings(watches: watches, results: swept)
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
  private func actOnFindings(watches: [Watch], results: [WatchPollResult]) async {
    // No empty-list guard here: `sweep()`'s own early return is the only
    // caller that could reach this with an empty `watches`, and that return
    // happens before this is ever called — clearing `demotions` there
    // instead (see `sweep()`) is what actually reaches the empty-list case.
    let floor = Preferences().freeSpaceFloor
    let resultsByLogin = Dictionary(uniqueKeysWithValues: results.map { ($0.login, $0) })

    var newDemotions: [String: AutoDownloadPolicy.Reason] = [:]
    var toSubmit: [(watch: Watch, archives: [ChannelArchive])] = []

    for watch in watches {
      // A failed fetch reads as no findings here, exactly the flattening
      // `WatchPollResult.findings`'s own doc comment says a *health* check
      // must not use — but this is not one. The floor and destination
      // checks below are unaffected by whether the feed answered, and a
      // watch with nothing found submits nothing regardless of why.
      let findings = resultsByLogin[watch.login]?.findings ?? []
      let destination = watch.settings.destination
      let destinationExists = FileManager.default.fileExists(atPath: destination.path)
      // An unreadable volume is treated as below the floor, not as
      // unlimited. `decide()` takes this figure on faith, and the failure
      // mode of guessing "plenty of room" is an unattended multi-gigabyte
      // download; the failure mode of guessing "none" is a channel sitting
      // notify-only until the next sweep re-probes. Only the second is
      // recoverable by doing nothing.
      let availableBytes = VolumeSpace.live.availableBytes(destination) ?? 0

      switch AutoDownloadPolicy.decide(
        watch: watch, findings: findings, availableBytes: availableBytes,
        destinationExists: destinationExists, floor: floor)
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

    guard !toSubmit.isEmpty else { return }

    // Resolved once and reused for every submission below — the same
    // engine `DownloadTwitchVideoIntent.perform()` binds once, for the same
    // reason its own comment gives: a second call was never wrong, only
    // harder to read.
    guard case .ready(let controller) = await QueueHost.shared.ready() else { return }

    // Sequential, matching `WatchPoll.sweep`'s own reasoning
    // (`docs/twitch-channel-api.md` §4): issuing a dozen submissions at once
    // is the traffic shape that document warns about, and `QueueEngine`
    // serialises the actual downloads anyway, so concurrency here would only
    // buy a burst of requests with nothing to show for it.
    for (watch, archives) in toSubmit {
      for archive in archives {
        await submit(archive, from: watch, into: controller)
      }
    }
  }

  /// Submits one archive through the one composition path, then marks it
  /// seen — never the reverse, and never on a thrown failure.
  ///
  /// **Marked seen only after `submit` succeeds.** A throw means `submit`
  /// refused before ever reaching the queue — an unrecognised link, a
  /// composite Oxbow could not build — and marking it seen anyway would
  /// bury a real archive with nobody having looked at it, breaking the one
  /// promise this feature makes. A success, `.queued` or `.alreadyQueued`
  /// alike, means the archive is accounted for either way, so both mark it.
  private func submit(_ archive: ChannelArchive, from watch: Watch, into controller: QueueController) async {
    do {
      _ = try await IntentSubmission.submit(
        link: archive.id,
        quality: watch.settings.qualityCap,
        output: watch.settings.output,
        chatSize: watch.settings.chatSize,
        destination: watch.settings.destination,
        existingJobs: controller.jobs,
        into: IntakeModel(controller: controller))
      markSubmitted(archive.id, login: watch.login)
    } catch {
      // Left as a finding for a person to retry through the intake window,
      // exactly as `docs/design/channel-watching.md` §6.3 already does for
      // a failure discovered later, in the queue rather than at
      // composition. Nothing here retries it: a durable refusal fails
      // identically next sweep too.
      //
      // **Known limitation, not fixed here:** a throw here means no `Job`
      // was ever created — `IntentSubmission.submit` can refuse before that
      // point, for an unrecognised link or a composite whose parent
      // broadcast has expired so there is no chat to download. Such an
      // archive is never marked seen, so the automatic path retries it
      // every sweep, forever, each retry costing a metadata fetch. Task 4's
      // failed-download rule cannot see it either, since that watches
      // `Job.status` and no job exists to watch. Nothing is silently lost —
      // the row stays visible as an ordinary finding, so a person can still
      // Add it and read the refusal in the intake window — but the retry
      // cost is real and unbounded. The obvious fix is a per-archive
      // refusal counter, and that is deliberately not being added now: it
      // is more of exactly the persistent per-archive state this feature
      // has been bitten by repeatedly (see `seen` itself, and `demotions`
      // above).
    }
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
}
