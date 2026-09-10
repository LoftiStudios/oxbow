import Foundation
import Observation
import OxbowKit

/// The Watching list: what the last sweep found, and the two things a person
/// can do about it.
///
/// **Not the only writer to `watches.json` any more.** This used to be —
/// polling was read-only by design (`docs/design/channel-watching.md` §4),
/// and the seen-set changed only when someone Added or Ignored. Automatic
/// downloading added two more: `WatchPoller.markSubmitted` marks an archive
/// seen the moment it queues it, and `AutoDownloadObserver.forget` un-marks
/// one the moment its job fails. Both write through their own `WatchStore`
/// over the same file, out of band, with nobody looking — which is exactly
/// why `rebuild()` reconciles every section (and, now, the `dismissed`
/// overlay) against each watch's own persisted `seen` on every read, rather
/// than trusting only what this model itself last wrote.
@MainActor
@Observable
final class WatchingModel {

  /// One channel's part of the list.
  struct Section: Identifiable, Equatable {
    var login: String
    var displayName: String

    /// The channel's avatar, from `Watch.avatarURL`. Nil for a channel added
    /// before that field existed; nothing backfills it, because the profile
    /// request is deliberately off the sweep's path.
    var avatarURL: URL?
    /// One row per archive this channel is offering or has acted on, each
    /// carrying what it currently is.
    ///
    /// **Replaces the bare `[ChannelArchive]` this used to hold.** A row is
    /// no longer only a finding — it may be queued, downloaded, or a
    /// download whose file has since gone — so the view needs the state
    /// alongside the archive rather than inferring it from which list the
    /// archive was in.
    var rows: [Row]
    /// Why this channel produced nothing, when that is the reason.
    ///
    /// Distinct from `rows.isEmpty`, and that distinction is the point:
    /// §7 requires a parse failure to read as a visible error rather than as
    /// "no new videos". A quiet channel has a nil failure and an empty list;
    /// a broken one has a message.
    var failure: String?
    /// What this channel is frozen to download at, read in
    /// `IntakeModel.optionsSummary`'s own register — same fields, same
    /// separator, same terse phrasing — so a quality cap or a destination
    /// does not read differently depending on which window shows it.
    ///
    /// `docs/design/channel-watching.md` §3.2: a watch's settings are frozen
    /// at add time and never surface again on their own, so this is the one
    /// place left that can still answer "what did I actually sign this
    /// channel up for?"
    var settingsSummary: String
    /// Whether this channel fetches on its own rather than only telling.
    ///
    /// Off by default and consequential (§2, §11.1) — a watch that has it on
    /// has to look different from one that does not, or the one control that
    /// matters most is also the one nobody can see they turned on. Automatic
    /// downloading is real now (`WatchPoller.actOnFindings`); this shows the
    /// stored intent, not a running behaviour, which is what makes it correct
    /// to read even while a sweep is between decisions.
    var downloadsAutomatically: Bool

    var id: String { login }
  }

  /// One archive, and what it currently is.
  struct Row: Identifiable, Equatable {
    var archive: ChannelArchive
    var state: ArchiveRowState
    var id: String { archive.id }
  }

  private(set) var sections: [Section] = []

  /// The current watch list, kept in step with `watches.json` so a section
  /// can show what its channel is set to, and so a channel that has never
  /// been polled — just added, or waiting for its first sweep — still gets
  /// one. Refreshed at the top of every `rebuild()`, not only at `init`,
  /// because the file can gain or lose a channel (`Add Channel`,
  /// `stopWatching`) between sweeps.
  private(set) var watches: [Watch] = []

  /// **Counts only rows a person still has to act on.** A queued or
  /// downloaded row is in the list but is not waiting for anybody, and a
  /// badge that counted them would never reach zero.
  var unreadCount: Int {
    sections.reduce(0) { $0 + $1.rows.filter { $0.state == .available }.count }
  }

  private let store: WatchStore

  /// Where this channel's video rows live, so that un-watching can let go of
  /// them.
  ///
  /// **No default, deliberately.** There is no path that is correct to fall
  /// back to. A call site that omitted this would still stop watching and
  /// still look entirely healthy, while `stopWatching` read and rewrote
  /// whatever the default happened to point at — which, for a store that is
  /// asked to *delete* rows, means silently emptying a file nobody asked it
  /// to touch. The same reasoning `WatchPoller.init` gives for its own copy,
  /// with the stakes one step higher because this one removes.
  private let videoRecordStore: VideoRecordStore

  /// Lets go of every stored image outside the given keep-set.
  ///
  /// A closure rather than an `ImageStore`, because of when the two are
  /// built: `OxbowApp` stands its image store up *after* it constructs this
  /// model, so there is nothing to hand in at construction. Reading it at
  /// call time — which is the only time the answer matters — side-steps that
  /// ordering entirely, and keeps this model testable without an actor, the
  /// same reason `openIntake` and `queue` are closures.
  ///
  /// Defaulted to a no-op, unlike `videoRecordStore` above, because the two
  /// failures are not comparable: an un-supplied purge leaves a few kilobytes
  /// of thumbnails on disk, an un-supplied record store rewrites the wrong
  /// file.
  private let purgeImages: (Set<URL>) -> Void

  /// Where this channel's stored `info` payloads live, so that un-watching
  /// can let go of the ones whose rows it drops.
  ///
  /// A payload is a file of its own under `payloads/<id>.txt` rather than a
  /// field in `videos.json` (`AppComposition.payloadDirectory`), so dropping
  /// a row does not take its payload with it — nothing on disk connects the
  /// two except the id, and only this call knows which ids went.
  ///
  /// Optional with a nil default for the reason `purgeImages` gives: an
  /// un-supplied remover leaves a few kilobytes of text on disk, which is not
  /// comparable to an un-supplied `videoRecordStore` rewriting the wrong file.
  private let payloads: PayloadStore?

  private let openIntake: (ChannelArchive, Watch) -> Void

  /// Queues one archive with its channel's frozen settings, answering with a
  /// sentence when it could not. Injected so this model stays testable
  /// without a `QueueController`, the same reason `openIntake` is a closure.
  private let queue: (ChannelArchive, Watch) async -> String?

  /// The queue's jobs as of the last publication, for `rebuild()` to derive
  /// row state from.
  ///
  /// **Display only.** `docs/design/channel-watching.md` §4 forbids deriving
  /// the *seen-set* from the queue — a removed job would silently license a
  /// re-download — and nothing here does: this decides a badge, and whether
  /// a row is listed at all (see `rebuild()`). Losing a job costs a row its
  /// place and its history; it never un-marks anything. Stage 3's store
  /// fixes that by not depending on the queue at all.
  private var jobs: [Job] = []

  /// How a delivered file's presence is answered. Injected so a test needs
  /// no disk; the live wiring hands in `ArchiveRowState.FileAnswer.resolve`
  /// over plain `FileManager` probes — deliberately not `VolumeSpace`, whose
  /// accessors resolve through `nearestExisting` and walk *up* to the
  /// nearest existing ancestor. That is right for asking about a volume's
  /// *capacity*, where any ancestor sits on the same disk, and wrong here:
  /// for an unmounted volume it lands on `/Volumes` itself, which always
  /// exists, so it would answer non-nil and read an unplugged drive as a
  /// deleted file (`ArchiveRowState.FileAnswer.resolve`'s own doc comment
  /// has the full reasoning, and §4.1 of `docs/design/channel-history.md`
  /// has it measured against real hardware).
  private let fileAnswer: (URL) -> ArchiveRowState.FileAnswer

  /// Archive ids `markSeen` could not persist.
  ///
  /// **Vestigial by design, kept for one narrow case.** This used to be the
  /// only thing standing between a dismissal and the row it hid reappearing —
  /// `rebuild()` filtered `latest` through this overlay and nothing else. It
  /// no longer carries that weight: `rebuild()` now reconciles every section
  /// against the watch's own persisted `seen` set (`Watch.findings(in:)`),
  /// and `markSeen` persists that write *before* it ever calls `rebuild()`,
  /// so a row is hidden by `seen` before this overlay is even consulted. The
  /// one case left is `markSeen`'s write failing outright (deliberately best
  /// effort — see that method's own comment), and this overlay **does not**
  /// rescue it: `seen` on disk never gains the id, so `rebuild()`'s pruning
  /// below drops it from here in the same pass and the row comes straight
  /// back. That is deliberate. Oxbow holds no record that the archive was
  /// ignored, and a row hidden on the strength of a write that failed would
  /// be the app showing a state it did not manage to store. The banner
  /// `markSeen` sets says so in as many words.
  ///
  /// Narrowed back down by `apply(_:)`, the same way it always was, so a
  /// failed id does not sit here forever once a sweep stops carrying it at
  /// all — an archive that has actually expired off the channel. `WatchPoll
  /// .sweep` no longer excludes an id merely for being seen, so becoming
  /// seen on its own does not shrink this set the way it once did; that is
  /// harmless here, because `rebuild()`'s own reconciliation against `seen`
  /// already hides a seen row regardless of whether this overlay still names
  /// it.
  ///
  /// **Also narrowed by `rebuild()`, against every watch's own `seen` — this
  /// is the second, newer way an id must stop being masked here.** A manual
  /// Add persists the archive into `seen` and into this overlay together
  /// (`markSeen`). If that download later fails, `AutoDownloadObserver
  /// .forget` un-marks it — through a different `WatchStore` instance over
  /// the same file, out of band, with nobody looking — but this overlay
  /// never heard about that: it only ever narrows itself in `apply(_:)`,
  /// against a sweep's *found* ids, and the archive is still found (it has
  /// not expired). Without reconciling against `seen` too, the row would
  /// stay masked here even though the watch itself now says it is unseen,
  /// and it would only reappear after a relaunch throws this whole set away.
  /// `rebuild()` is where every other reconciliation against `seen` already
  /// happens (`Watch.findings(in:)`), so this is that same rule applied one
  /// layer up, to the overlay sitting in front of it.
  private var dismissed: Set<String> = []

  /// The latest sweep. `rebuild()` looks a login up in here; it never
  /// iterates this directly — see `rebuild()`'s own comment for why `watches`
  /// is the collection that drives what gets shown.
  private var latest: [WatchPollResult] = []

  /// Set when Stop Watching refused rather than removing anything. The same
  /// idiom as `AddChannelModel.addFailure`: a context menu action has no
  /// return value for a caller to inspect, so the reason has to land
  /// somewhere a view can read it after the fact.
  private(set) var stopWatchingFailure: String?

  /// Set when Ignore or Add could not persist to the watch's seen-set because
  /// the store could not be read — `markSeen`'s own counterpart to
  /// `stopWatchingFailure` and `AddChannelModel.addFailure`.
  ///
  /// **Why this exists at all.** `markSeen` already hides the row via
  /// `dismissed` before it ever touches the store, so an unreadable
  /// `watches.json` used to fail *completely* silently: the row vanished,
  /// `add(_:from:)` opened no intake window, and nothing on screen said why.
  /// The other three writers of `watches.json` — `AddChannelModel.add()` in
  /// both its modes, and `stopWatching` below — all refuse loudly on the
  /// identical condition; this is `markSeen`'s turn to do the same rather
  /// than being the one silent exception.
  private(set) var markSeenFailure: String?

  /// Why the last Add did not reach the queue, or nil. Cleared by the next
  /// Add and by `rebuild()`, the same lifetime the two failure banners
  /// beside it already have.
  private(set) var submissionFailure: String?

  init(
    store: WatchStore,
    videoRecordStore: VideoRecordStore,
    openIntake: @escaping (ChannelArchive, Watch) -> Void,
    queue: @escaping (ChannelArchive, Watch) async -> String? = { _, _ in nil },
    // **Fails closed.** The previous default answered `.present` for any URL
    // at all, which was survivable only while this was consulted solely for a
    // path a finished job had already delivered. It is now also asked about a
    // path this app merely *would* have written, so a caller that forgot to
    // supply a real check would report every archive on the channel as
    // downloaded. Claiming nothing is the only safe thing an absent answer can
    // do; the one production call site passes a real filesystem check.
    fileAnswer: @escaping (URL) -> ArchiveRowState.FileAnswer = { _ in .absent },
    purgeImages: @escaping (Set<URL>) -> Void = { _ in },
    payloads: PayloadStore? = nil
  ) {
    self.store = store
    self.videoRecordStore = videoRecordStore
    self.openIntake = openIntake
    self.queue = queue
    self.fileAnswer = fileAnswer
    self.purgeImages = purgeImages
    self.payloads = payloads
    // Populates `sections` from whatever is already watched before the first
    // sweep ever lands — requirement 1's "never polled" case starts the
    // instant a channel is added, not once `WatchPoller` gets around to it.
    rebuild()
  }

  /// The `[Job]` facts a row can actually turn on, as of the last rebuild.
  ///
  /// Everything `ArchiveRowState.state` and `rebuild()`'s visibility rule
  /// read: which archive a job is for, what status it is in, and where a
  /// finished one delivered. Nothing else — see `updateJobs`.
  private struct JobFacts: Equatable {
    var mediaIdentifier: String?
    var status: JobStatus
    var deliveredFile: URL?

    init(_ job: Job) {
      mediaIdentifier = job.mediaIdentifier
      status = job.status
      deliveredFile = job.deliveredFiles.first
    }
  }

  private var jobFacts: [JobFacts] = []

  /// Republishes the rows against a new view of the queue — but only when
  /// the queue has said something a row can hear.
  ///
  /// Called whenever `controller.jobs` changes, so a job finishing reaches
  /// the pane immediately rather than waiting for the next hourly sweep.
  ///
  /// **`QueueEngine.publish()` is not debounced, and it fires on every helper
  /// status line — its own comment says they "arrive by the hundreds".** Each
  /// one assigns `QueueController.jobs`, and `Step.progress` participates in
  /// `Step`'s synthesized `Equatable`, so `[Job]` compares unequal on every
  /// tick and `QueueView`'s `.onChange` calls this hundreds of times a second
  /// for the whole length of a download. Rebuilding on each of those would
  /// re-read and decode `watches.json` from disk on the main actor at that
  /// rate, probe every delivered file with it, and — because `rebuild()`
  /// clears the three failure banners — wipe a refused Add's explanation off
  /// the screen before anyone could finish reading it.
  ///
  /// A percentage is not news to this pane, so comparing the facts above is
  /// what decides whether anything happens. **Do not collapse this back to
  /// comparing `jobs` themselves**: that comparison is true on every progress
  /// tick, which is the thing this exists to stop.
  func updateJobs(_ jobs: [Job]) {
    self.jobs = jobs

    let facts = jobs.map(JobFacts.init)
    guard facts != jobFacts else { return }
    jobFacts = facts

    rebuild()
  }

  /// Replaces the list with a new sweep.
  ///
  /// Wholesale, not merged: the inbox is derived rather than accumulated
  /// (§4), so an archive that has expired since the last sweep should stop
  /// appearing rather than linger as a row nothing can download.
  func apply(_ results: [WatchPollResult]) {
    latest = results

    let found = results.reduce(into: Set<String>()) { ids, result in
      if case .found(let archives) = result.outcome {
        ids.formUnion(archives.map(\.id))
      }
    }
    dismissed.formIntersection(found)

    rebuild()
  }

  func ignore(_ archive: ChannelArchive, from login: String) {
    markSeen(archive.id, in: login)
  }

  /// Queues the archive with its channel's frozen settings.
  ///
  /// **This used to open the intake window instead.** A row's Add offered a
  /// prefilled form built from settings the person had already chosen once,
  /// when they added the channel — quality, output and destination are
  /// frozen onto the watch precisely so they do not have to be chosen again.
  /// Asking a second time made the primary action on every finding a
  /// two-step, and made the button's label a lie. Intake is still reachable
  /// for the case that actually needs it — see `openInIntake(_:from:)`.
  ///
  /// **Seen only once it is queued**, which is the opposite of what this did
  /// before and is now the honest answer: there is no form left to abandon,
  /// so "answered" and "queued" are the same event. A refusal leaves the row
  /// where it is, with `submissionFailure` saying why, rather than marking
  /// an archive handled that nothing is handling.
  ///
  /// **The row does not vanish when it is marked seen**, which is the whole
  /// point of queueing first: `rebuild()` keeps any archive the queue holds
  /// a job for, so this reads as the row turning into "In queue" rather than
  /// as the video the person just asked for leaving the screen.
  func add(_ archive: ChannelArchive, from login: String) async {
    submissionFailure = nil

    // Read from disk rather than from `watches`, and read it *here* rather
    // than letting `markSeen` do it later. The settings this composes the
    // job from have to be the ones actually saved — `AddChannelModel` in
    // edit mode rewrites them live through its own `WatchStore` — and an
    // unreadable file has to refuse out loud, exactly as `markSeen` already
    // does for the same condition. Guarding on the in-memory `watches`
    // instead made both cases silent: a stale snapshot composed the job from
    // superseded settings, and an unreadable store looked like a button that
    // did nothing.
    let current: [Watch]
    do {
      current = try store.load()
    } catch {
      rebuild()
      markSeenFailure = "Oxbow could not read the watch list: \(error.localizedDescription)"
      return
    }

    // Silent, unlike the read failure above: the channel being gone is a
    // normal race against a list already on screen, not an error.
    guard let watch = current.first(where: { $0.login == login }) else { return }

    if let failure = await queue(archive, watch) {
      submissionFailure = failure
      return
    }
    markSeen(archive.id, in: login)
  }

  /// Opens intake for this archive, prefilled — the secondary action, for
  /// the one thing queueing directly cannot do: trim it, or override a
  /// setting for this VOD alone.
  ///
  /// **Seen on open, not on the eventual download**, which is the rule the
  /// primary action used to follow and which still holds here: someone who
  /// opens the form and abandons it has still answered the question, and
  /// re-offering the row next sweep would be asking it again.
  func openInIntake(_ archive: ChannelArchive, from login: String) {
    guard let watch = markSeen(archive.id, in: login) else { return }
    openIntake(archive, watch)
  }

  /// Persists the id into the channel's seen-set and hides its row. Returns
  /// the watch it belonged to, or nil if the channel is no longer watched —
  /// which is not an error: the file can change under a list already on
  /// screen.
  ///
  /// **A failed save still hides the row and still returns the watch** — the
  /// action is never blocked or rolled back — **but now sets
  /// `markSeenFailure`**, so the banner says the row will come back on the
  /// next launch instead of the user having no idea whether Ignore or Add did
  /// anything at all. See the `store.save` call below for why silently
  /// swallowing the error, the behaviour before this, was worse than either
  /// alternative: it made a failed persist indistinguishable from a
  /// completed one.
  ///
  /// **`rebuild()` runs after the persist attempt, on every exit path.**
  /// `rebuild()` calls `refreshWatches()`, which re-reads `watches` from
  /// disk — so calling it before the write below would snapshot the file as
  /// it stood *before* this id was marked seen, and `watches` (and the
  /// `sections` built from it) would stay stale until something else
  /// happened to call `rebuild()` again. `dismissed.insert(id)` still comes
  /// first, so the row hides instantly regardless: the overlay only depends
  /// on that set, never on `refreshWatches()`'s snapshot.
  @discardableResult
  private func markSeen(_ id: String, in login: String) -> Watch? {
    dismissed.insert(id)

    var current: [Watch]
    do {
      current = try store.load()
    } catch {
      // Distinct from "this channel is no longer watched" below: that is a
      // normal, silent nil (the file can change under a list already on
      // screen), but this is the identical unreadable-store condition
      // `AddChannelModel.add()` and `stopWatching` already refuse loudly on.
      // Without this branch, `dismissed.insert(id)` above had already hidden
      // the row, so the whole thing failed with no window opened (`add(_:
      // from:)`'s `guard let watch = markSeen(...) else { return }`) and no
      // message anywhere — the row simply vanished.
      //
      // `rebuild()` before the assignment, not after: `rebuild()` itself
      // clears `markSeenFailure` as one of its own first steps (see its own
      // doc comment), so setting the message first would have it wiped out
      // by the very call meant to refresh `watches` around it.
      rebuild()
      markSeenFailure = "Oxbow could not read the watch list: \(error.localizedDescription)"
      return nil
    }

    guard let index = current.firstIndex(where: { $0.login == login }) else {
      rebuild()
      return nil
    }

    current[index] = current[index].marking([id])
    // Best effort — this does not throw, and (for `add(_:from:)`) intake
    // still opens even when the write below fails.
    //
    // **A failed save leaves the row exactly where it was, in the same
    // frame.** `dismissed.insert` above hid it, but `rebuild()` in the catch
    // prunes `dismissed` against what is actually on disk — and the write
    // that just failed is why disk does not have this id — so the overlay
    // gives the row straight back. That is the honest outcome: Oxbow has no
    // record that this archive was ignored, so continuing to offer it is
    // what the stored state actually says.
    //
    // It has not always been. Before `rebuild()` reconciled the overlay
    // against disk, a failed save left the row hidden for the rest of the
    // session and the re-offer arrived only on the next launch — which is
    // what the banner below used to promise. Both the pruning and the
    // banner's wording have been corrected since; if either changes again
    // they have to change together, or the app goes back to describing an
    // outcome it does not produce.
    //
    // Before any of it, the failure was silent, which made a failed save
    // indistinguishable from a completed one. An unresponsive button would
    // have been more honest than an action that looks done and was not, so
    // this sets `markSeenFailure`, the same as the read failure above, and
    // calls `rebuild()` first for the identical reason: it clears
    // `markSeenFailure` as one of its own first steps, so setting the
    // message before it would just have it wiped out again.
    do {
      try store.save(current)
    } catch {
      let result = current[index]
      rebuild()
      markSeenFailure = """
        Oxbow could not save the watch list, so this is still here. \
        \(error.localizedDescription)
        """
      return result
    }
    let result = current[index]
    rebuild()
    return result
  }

  /// Removes `login`'s watch and lets go of what it leaves behind, touching
  /// nothing about the other channels' settings or seen-sets.
  ///
  /// **Does not delete anything already downloaded.** It edits four things
  /// and only four: `watches.json` — the list of channels being watched —
  /// this channel's rows in the video record, the stored images nothing names
  /// any more, and the stored payloads of the rows it dropped. Never a file a
  /// past download produced, and never the row describing one. Stopping a
  /// watch and deleting its archive are two different decisions, and this
  /// makes only the first one.
  ///
  /// **Refuses rather than overwriting when the store cannot be read** — the
  /// same rule `AddChannelModel.add()` follows, guarding the identical bug:
  /// `try? store.load() ?? []` cannot tell "nothing else is watched" apart
  /// from "the file could not be read", and saving a filtered list built
  /// from the wrong one of those would silently erase every other channel
  /// this call was never asked to touch.
  func stopWatching(_ login: String) {
    let existing: [Watch]
    do {
      existing = try store.load()
    } catch {
      stopWatchingFailure = """
        Oxbow could not read the watch list, so \(login) was not stopped. \
        \(error.localizedDescription)
        """
      return
    }

    // Held onto rather than written inline, because the purge further down
    // needs the same list: these are the channels still being watched, and
    // their avatars are half of what the image store is still legitimately
    // holding.
    let surviving = existing.filter { $0.login != login }

    do {
      try store.save(surviving)
    } catch {
      stopWatchingFailure = "Oxbow could not save the watch list: \(error.localizedDescription)"
      return
    }

    // Only once the watch list itself is safely saved, never before: both
    // branches above returned on failure, leaving the channel still watched,
    // and a channel that is still watched must keep every row it has.
    //
    // What goes: this channel's watch state, and the rows it has nothing to
    // show for. What stays: a row with a delivered file, or one whose
    // download is still in the queue. Those are what Get Info renders, what
    // makes re-adding this channel light up with what you already have, and —
    // for a video that has since expired off Twitch — the only surviving
    // trace that it ever existed. A row dropped here cannot be fetched back.
    //
    // **Load, modify and save with no suspension point in between.**
    // `videos.json` has four writers, and they are safe against each other
    // for exactly one reason: each is `@MainActor` and does its whole
    // load-modify-save without an `await`, so no other writer can interleave
    // and have its half of the record overwritten. `VideoRecordStore.load`
    // and `.save` are both synchronous precisely so this can be. An `await`
    // here, or a `Task { }` around this, reintroduces the interleaving
    // silently and with no failing test — `VideoRecorder`'s doc comment
    // states the same rule for the same file.
    //
    // Best effort, like every other writer of this file: a record that cannot
    // be read is a stale row, not a reason to refuse a removal the watch list
    // has already committed to.
    if var library = try? videoRecordStore.load() {
      // Which videos still have a job, from the queue facts this model
      // already keeps for its rows. A row whose download is mid-flight has
      // no delivered file to protect it yet, and this is what protects it
      // instead.
      let jobbed = Set(jobFacts.compactMap(\.mediaIdentifier))

      // Taken before the mutation, because afterwards there is nothing left
      // to ask: `removeWatch` drops rows outright rather than marking them,
      // so "which ids went" only exists as the difference between the two
      // sides of this line.
      let before = Set(library.videos.keys)
      library.removeWatch(login: login, keepingVideosWithJobs: jobbed)
      let dropped = before.subtracting(library.videos.keys)

      // Images are let go of only once the surviving rows are actually on
      // disk. If that save failed, the file still names every row this call
      // just dropped in memory, and purging against the in-memory keep-set
      // would delete the images those rows still point at — for an expired
      // video, the stored copy is the only one left.
      //
      // Deliberately outside the window above, and the reason it can be: the
      // purge is cleanup, not part of the record write. Nothing else reads
      // the image directory for correctness, so it is free to be asynchronous
      // and to land whenever it lands.
      //
      // **The keep-set is both halves of what the store holds.** One
      // `ImageStore` directory backs two kinds of image: a row's thumbnails,
      // and a watched channel's avatar (`ChannelCard` draws it through the
      // same store). The record knows only the first — `referencedImageURLs`
      // is a method on the video record, and the record has never heard of a
      // watch — so handing it over alone declares every other channel's
      // avatar an orphan and deletes it. Not data loss: `avatarURL` survives
      // in `watches.json` and the next draw re-fetches. But re-fetching is
      // exactly what the store exists to avoid — a cold launch with the
      // network down should still look like the design, and after an
      // un-watch it would not. The union is assembled here because this is
      // the only place that holds both halves at once
      // (`docs/design/video-record.md` §3.6).
      //
      // A dropped row's payload goes with it, on the same condition and for
      // the same reason. `payloads/<id>.txt` is a file of its own beside
      // `videos.json` (§3.3), so nothing removes it when its row goes — and
      // a payload whose row is gone is unreachable, since the id in the
      // filename is the only way anything ever finds it. Removing it before
      // the save would be the image mistake in a second form: a save that
      // failed leaves the row on disk still expecting its payload to be
      // there, and a payload cannot be re-fetched for a video Twitch has
      // dropped.
      if (try? videoRecordStore.save(library)) != nil {
        purgeImages(library.referencedImageURLs()
          .union(surviving.compactMap(\.avatarURL)))
        payloads?.remove(ids: dropped)
      }
    }

    // `rebuild()` below clears `stopWatchingFailure` on its own — see its own
    // doc comment on why that, not an explicit `nil` here, is the right
    // place for it.

    // This channel's own ids would otherwise linger in the overlay forever:
    // `apply(_:)`'s `formIntersection` only drops an id once a sweep
    // computed *after* the write stops carrying it, and a stopped channel
    // gets no more sweeps to make that happen. Left alone, a later re-add
    // whose first sweep happens to reuse one of those VOD ids would have a
    // genuinely new archive hidden by a dismissal earned by a watch that no
    // longer exists.
    //
    // Subtracts the watch's own persisted `seen` — every id it ever marked,
    // not only whatever the most recent sweep still happened to be carrying.
    // `seen` only grows, so it is the complete history; the latest sweep is
    // only ever a subset of it (anything it already excluded via that same
    // `seen`), and cleaning up against the subset would leave exactly the
    // ids a *successful* Ignore or Add had already excluded from it still
    // sitting in the overlay, ready to hide a re-added watch's identical
    // finding for no reason a re-add's own fresh `seen` would ever explain.
    if let removed = existing.first(where: { $0.login == login }) {
      dismissed.subtract(removed.seen)
    }

    // `latest` itself is left untouched, deliberately. `login` is no longer
    // in `watches` the moment `refreshWatches()` re-reads the file `rebuild()`
    // is about to trigger, and `rebuild()` only ever looks a result up for a
    // login it is already showing a section for — so a stale entry sitting
    // here for an unwatched channel is inert, not a leak. Removing it used to
    // matter when `rebuild()` iterated `latest` directly; now that `watches`
    // is what it iterates, there is nothing left for that removal to guard.
    rebuild()
  }

  /// Re-reads `watches.json` and rebuilds `sections` from it.
  ///
  /// **Why a caller ever needs to ask for this.** `sections` otherwise only
  /// changes when a sweep lands (`apply(_:)`) or this model makes its own
  /// write (`markSeen`, `stopWatching`) — nothing here notices a write made
  /// by a *different* `WatchStore` instance, such as `AddChannelWindow`'s.
  /// Without an explicit re-read, a channel added from that window stays
  /// invisible until the next hourly sweep, which is the exact flow the
  /// toolbar button exists for appearing to do nothing. `QueueView` calls
  /// this when the Watching pane appears, and `OxbowApp` calls it once the
  /// Add Channel window closes — see each call site's own comment.
  func refresh() {
    rebuild()
  }

  /// Re-reads the watch list so `rebuild()` can show every channel actually
  /// being watched, including one no sweep has produced a result for yet —
  /// added moments ago, or resolved by `stopWatching` just above.
  ///
  /// Best effort: a failed read leaves `watches` exactly as it was, the same
  /// posture `markSeen`'s write takes — every write this model makes already
  /// refuses outright rather than leaving a state this would need to
  /// recover from.
  private func refreshWatches() {
    if let loaded = try? store.load() {
      watches = loaded
    }
  }

  /// Rebuilds `sections`, and — as a side effect — clears any stale write
  /// failure still on screen.
  ///
  /// **`watches` is the spine; `latest` is a lookup.** This used to iterate
  /// `latest` — a poll snapshot owned by `WatchPoller`, current only as of
  /// whichever sweep produced it — and append `watches` afterwards for
  /// whatever that snapshot missed. Every derived
  /// section was keyed on the stale collection, with the authoritative one
  /// reduced to an afterthought, and every one of this type's races traced
  /// back to that: a section for a channel `stopWatching` had already
  /// removed, or a channel not yet appearing until its own entry showed up
  /// in a sweep. Mapping over `watches` instead makes both errors
  /// structural rather than guarded against: a login not in `watches` gets
  /// no section because it is never iterated, and a login in `watches` gets
  /// exactly one section because it is iterated exactly once — the "channel
  /// never polled" case is no longer a second pass patching a gap, just the
  /// ordinary outcome of `latest` not having an entry yet.
  ///
  /// **Why the failures clear here rather than only where they were set.**
  /// `stopWatchingFailure` used to be cleared only by a *later successful
  /// stop* — an arbitrary condition that cut both ways: it left the banner
  /// on screen through a pane switch, an Ignore, an Add, or a sweep landing
  /// (`refresh()`, `markSeen`, `apply(_:)` all reach `rebuild()` without
  /// ever touching it), and yet a successful stop of a *different* channel
  /// cleared it while the login that actually failed was still watched,
  /// implying the problem was resolved when it was not. Both `stopWatching`
  /// and `markSeen`'s own failure branches `return` before ever reaching
  /// this method, so setting a failure and having it clear here never race —
  /// the banner survives exactly until the next thing happens, which is an
  /// honest "this is no longer the latest word" rather than a specific,
  /// misleading claim about what that next thing was.
  /// One channel's rows, sourced from the record rather than from whatever
  /// this sweep happened to return.
  ///
  /// **This is what stops a row's history being a lease on the queue.** Rows
  /// used to be built from the sweep's archives minus the watch's seen-set,
  /// joined against the queue's jobs — so an archive disappeared the moment it
  /// was marked seen, and a completed download vanished when a person cleared
  /// its job out of the queue. `docs/design/channel-history.md` §7.2 names
  /// that as scaffolding to be replaced, and this replaces it.
  ///
  /// **The live sweep still wins where it overlaps.** An archive Twitch listed
  /// this poll carries a real `status`, which is what tells a still-recording
  /// broadcast apart from a finished one; the record has no equivalent. So a
  /// recorded row is only synthesised into a `ChannelArchive` when the sweep
  /// did not return one.
  ///
  /// **Two filters, and they answer different questions.** `isVisibleByDefault`
  /// asks what a person has already decided about (§5.1); the live-or-held
  /// test below asks whether there is anything left to show. An archive that is
  /// gone from Twitch and was never downloaded is a headstone — §5.2 keeps
  /// those behind a filter, so until that filter exists they simply do not
  /// render.
  ///
  /// `dismissed` still applies, because an Ignore that has not yet reached
  /// disk has to hold on screen — see that property's own doc comment.
  private func rows(
    for watch: Watch, liveArchives: [ChannelArchive], library: VideoLibrary
  ) -> [Row] {
    let live = Dictionary(liveArchives.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    let recorded = library.videos.filter { $0.value.login == watch.login }

    // **A union of the two sources, not one replacing the other.** The sweep
    // is authoritative for what Twitch is listing right now; the record adds
    // what a person still has that Twitch has since dropped. Sourcing rows
    // from the record alone looks equivalent — `WatchPoller.record` writes
    // every swept archive before this rebuilds — but that is an ordering, not
    // a guarantee: the record write is best-effort by design, and one that
    // failed would blank a channel that had just returned a hundred archives.
    // Depending on it would reintroduce, from the other direction, exactly the
    // disappearing-rows bug this change exists to fix.
    let candidates: [(archive: ChannelArchive, record: VideoRecord?)] =
      liveArchives.map { ($0, recorded[$0.id]) }
      + recorded.values.filter { live[$0.id] == nil }.map { (Self.archive(from: $0), $0) }

    // State is resolved for every candidate before anything is filtered,
    // because whether a person still has the file is part of deciding whether
    // the row belongs on screen at all — and that answer comes from the
    // filesystem, not from the record's own opinion of itself.
    return candidates
      .map { candidate in
        (archive: candidate.archive,
         state: ArchiveRowState.state(
           for: candidate.archive, jobs: jobs,
           recordedPath: candidate.record?.deliveredPath,
           // Only worth deriving where the record has no answer of its own —
           // a recorded path outranks it anyway, and this builds a
           // `DateFormatter` per row.
           expectedPath: candidate.record?.deliveredPath == nil
             ? Self.expectedPath(for: candidate.archive, watch: watch)
             : nil,
           file: fileAnswer))
      }
      // **One precedence, highest first**, because every rule below was
      // learned from a row that vanished when it should not have:
      //
      // 1. You have the file. §5.1 puts that in the default view
      //    unconditionally, and no mark below can tell a download apart from
      //    a dismissal — `Watch.seen` records both, and the migration turned
      //    every pre-record download into `skipped` because a bare id carried
      //    no evidence of which it was.
      // 2. It is in flight. Every path that queues an archive marks it seen
      //    in the same breath, and `add(_:from:)` leaves it briefly both
      //    dismissed *and* queued — so without this the row would leave the
      //    list at the exact moment a person asked for it.
      // 3. An Ignore not yet written to disk.
      // 4. The recorded state.
      // 5. The legacy seen-set, where no state exists yet.
      // 6. Otherwise it shows only while Twitch is still listing it.
      .filter { row in
        if row.state.holdsAFile { return true }
        if row.state == .queued || row.state == .running { return true }
        if dismissed.contains(row.archive.id) { return false }
        if let state = library.watchStates[row.archive.id] {
          return state.isVisibleByDefault
        }
        if watch.seen.contains(row.archive.id) { return false }

        // Off Twitch and nothing on disk: a headstone, hidden until §5.2's
        // filter can surface it deliberately.
        return live[row.archive.id] != nil
      }
      .map { Row(archive: $0.archive, state: $0.state) }
      // Newest first, the order the sweep already returns and the one a
      // channel page reads in.
      .sorted { $0.archive.publishedAt > $1.archive.publishedAt }
  }

  /// Where this archive's download would land, if it were made now.
  ///
  /// **How a download made before the record existed is recognised.** The
  /// destination is the channel's own frozen setting and the filename is
  /// deterministic, so the file can be looked for exactly where this app would
  /// have put it. `ArchiveRowState` treats the answer as the weaker evidence
  /// it is — see its own comment on why only `present` counts.
  ///
  /// **Derived the same way the writer derives it, or it silently never
  /// matches.** `IntakeModel.load` composes the name from the streamer's
  /// display name, the video's date and its title, reserving room for the
  /// longest suffix any output can take; every argument here mirrors that call.
  /// A divergence would not fail — it would simply stop finding files, which
  /// is the kind of bug that goes unnoticed.
  ///
  /// `Calendar.current` because the date is rendered in the timezone the file
  /// was written in, and both happen on this machine.
  private static func expectedPath(for archive: ChannelArchive, watch: Watch) -> String {
    let base = OutputNaming.baseName(
      streamer: watch.displayName,
      date: archive.publishedAt,
      title: archive.title,
      calendar: .current,
      reservingSuffixBytes: OutputSuffix.longestBytes)
    return watch.settings.destination
      .appending(path: base + OutputSuffix.video)
      .path(percentEncoded: false)
  }

  /// A recorded video, dressed as the archive the row rendering expects.
  ///
  /// Only reached for a video the current sweep did not return, which means
  /// Twitch is no longer listing it. `status` is therefore a guess with no
  /// evidence behind it, and `.recorded` is the harmless one: every state a
  /// row in this position can reach — `downloaded`, `unverifiable` — is
  /// decided by the recorded path before `isDownloadable` is ever consulted.
  private static func archive(from record: VideoRecord) -> ChannelArchive {
    ChannelArchive(
      id: record.id,
      title: record.title ?? record.id,
      duration: .seconds(record.durationSeconds ?? 0),
      publishedAt: record.publishedAt ?? .distantPast,
      status: .recorded,
      thumbnailURL: record.thumbnailURLs.first,
      categoryName: record.categoryName)
  }


  private func rebuild() {
    stopWatchingFailure = nil
    markSeenFailure = nil
    submissionFailure = nil

    refreshWatches()

    // `dismissed` yields to disk here, in both directions — see that
    // property's own doc comment for the concrete failure this closes.
    // Pruned against every watch actually on disk, not just whichever
    // section is being built below, because an id an observer un-marked
    // belongs to exactly one watch and this is one pass over all of them
    // rather than one lookup per archive.
    let stillSeen = watches.reduce(into: Set<String>()) { $0.formUnion($1.seen) }
    dismissed.formIntersection(stillSeen)

    // Read once for every section rather than per watch: one file, and a
    // channel can list a hundred archives. A failure reads as an empty
    // library — the same posture every other reader of this store takes,
    // because a row that cannot be built is a row missing from a list, never
    // an error worth interrupting a person over.
    let library = (try? videoRecordStore.load()) ?? VideoLibrary()

    sections = watches.map { watch in
      let outcome = latest.first(where: { $0.login == watch.login })?.outcome
      switch outcome {
      case .found(let archives):
        return Section(
          login: watch.login, displayName: watch.displayName,
          avatarURL: watch.avatarURL,
          rows: rows(for: watch, liveArchives: archives, library: library),
          failure: nil, settingsSummary: settingsSummary(for: watch.settings),
          downloadsAutomatically: watch.downloadsAutomatically)
      case .failed(let error):
        return Section(
          login: watch.login, displayName: watch.displayName,
          avatarURL: watch.avatarURL,
          rows: [], failure: error.localizedDescription,
          settingsSummary: settingsSummary(for: watch.settings),
          downloadsAutomatically: watch.downloadsAutomatically)
      case nil:
        // Never polled — added moments ago, or waiting on its first sweep
        // since launch (requirement 1) — rather than staying invisible
        // until a sweep finally reaches it.
        //
        // **Its recorded rows still render.** Before the record existed this
        // had to be empty, because a row could only be built from a sweep's
        // own archives; now what a person already has does not wait on a
        // network round trip to reappear.
        return Section(
          login: watch.login, displayName: watch.displayName,
          avatarURL: watch.avatarURL,
          rows: rows(for: watch, liveArchives: [], library: library),
          failure: nil, settingsSummary: settingsSummary(for: watch.settings),
          downloadsAutomatically: watch.downloadsAutomatically)
      }
    }
  }

  /// `IntakeModel.optionsSummary`'s own register, applied to a watch's
  /// frozen settings instead of one intake submission: the output first
  /// (folded with the chat size, when it applies), the quality cap, then the
  /// destination — the same order, the same "·" separator, the same terse
  /// phrasing, so a person does not learn a second vocabulary for the same
  /// four settings depending on which window shows them.
  private func settingsSummary(for settings: Watch.Settings) -> String {
    let outputLabel: String
    switch settings.output {
    case .videoWithChat: outputLabel = "Video + chat"
    case .video: outputLabel = "Video"
    }

    var summary = "\(outputLabel) · \(settings.qualityCap.label)"
    // Chat size is meaningless when nothing renders chat — `IntakeWindow`
    // hides its own picker on the same condition
    // (`IntakeModel.withholdsChatSizeFromSave`), so this withholds it from
    // the summary line for the identical reason.
    if settings.output == .videoWithChat {
      summary += " · \(settings.chatSize.rawValue.capitalized) chat"
    }
    summary += " · \(settings.destination.lastPathComponent)"
    return summary
  }
}
