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
  /// re-download — and nothing here does: this decides a badge. Losing a job
  /// costs a row its history, which stage 3's store fixes by not depending
  /// on the queue at all.
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
  /// one thing that reconciliation cannot cover is `markSeen`'s write
  /// failing outright (it is `try?`, deliberately best-effort — see that
  /// method's own comment): `seen` on disk never gains the id then, so this
  /// is what keeps the row hidden for the rest of the session regardless.
  ///
  /// Narrowed back down by `apply(_:)`, the same way it always was, so a
  /// failed id does not sit here forever once a sweep stops carrying it at
  /// all (which, for a channel `seen` already excludes it from, means the
  /// sweep excluded it too — `WatchPoll.sweep` applies the identical filter
  /// before this model ever sees the result).
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
    openIntake: @escaping (ChannelArchive, Watch) -> Void,
    queue: @escaping (ChannelArchive, Watch) async -> String? = { _, _ in nil },
    fileAnswer: @escaping (URL) -> ArchiveRowState.FileAnswer = { .present($0) }
  ) {
    self.store = store
    self.openIntake = openIntake
    self.queue = queue
    self.fileAnswer = fileAnswer
    // Populates `sections` from whatever is already watched before the first
    // sweep ever lands — requirement 1's "never polled" case starts the
    // instant a channel is added, not once `WatchPoller` gets around to it.
    rebuild()
  }

  /// Republishes the rows against a new view of the queue.
  ///
  /// Called whenever `controller.jobs` changes, so a job finishing reaches
  /// the pane immediately rather than waiting for the next hourly sweep.
  func updateJobs(_ jobs: [Job]) {
    self.jobs = jobs
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
    // Best effort — this does not throw, and does not undo `dismissed.insert`
    // above, so the row stays hidden and (for `add(_:from:)`) intake still
    // opens even when the write below fails. `dismissed` was already updated
    // before this write was attempted, and nothing rolls it back if it fails
    // — so a failed save does not cost "one re-offer on the next sweep": the
    // row stays hidden by the in-memory overlay for the rest of this session
    // (its id keeps coming back from every sweep, and `apply`'s
    // `formIntersection` keeps retaining it), and the re-offer only arrives
    // on the next launch, once `dismissed` itself is gone.
    //
    // That silent fallback used to be the whole story, which made a failed
    // save indistinguishable from a completed one — no hide-then-reappear, no
    // banner, nothing. An unresponsive button would have been more honest
    // than an action that looks done and was not, so this now sets
    // `markSeenFailure`, the same as the read failure above, and `rebuild()`
    // first for the identical reason: it clears `markSeenFailure` as one of
    // its own first steps, so setting the message before it would just have
    // it wiped out again.
    do {
      try store.save(current)
    } catch {
      let result = current[index]
      rebuild()
      markSeenFailure = """
        Oxbow could not save the watch list, so this will show up again the \
        next time Oxbow launches. \(error.localizedDescription)
        """
      return result
    }
    let result = current[index]
    rebuild()
    return result
  }

  /// Removes `login`'s watch and persists what is left, touching nothing
  /// else about the other channels' settings or seen-sets.
  ///
  /// **Does not delete anything already downloaded.** This edits
  /// `watches.json` — the list of channels being watched — never a file a
  /// past download produced. Stopping a watch and deleting its archive are
  /// two different decisions, and this makes only the first one.
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

    do {
      try store.save(existing.filter { $0.login != login })
    } catch {
      stopWatchingFailure = "Oxbow could not save the watch list: \(error.localizedDescription)"
      return
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
  /// `latest` — a poll snapshot owned by `WatchPoller`, computed against
  /// whatever the seen-set was minutes ago at sweep time — and append
  /// `watches` afterwards for whatever that snapshot missed. Every derived
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

    sections = watches.map { watch in
      let outcome = latest.first(where: { $0.login == watch.login })?.outcome
      switch outcome {
      case .found(let archives):
        // Reconciled against the watch's own `seen` set, not only the
        // in-memory `dismissed` overlay. `dismissed` only ever catches what
        // *this* model wrote through *this* `store` — a seen-set written
        // through a different `WatchStore`, which is exactly what
        // `AddChannelModel` does, would otherwise leave rows on screen the
        // watch itself already says are seen. Re-adding an already-watched
        // channel with Only new is the concrete case: its caption promises
        // "everything Twitch has right now is marked seen", but without
        // this the inbox kept showing them until the next sweep, up to an
        // hour later. `Watch.findings(in:)` is the same filter `WatchPoll`
        // itself applies, so this closes the whole class of "some other
        // writer changed `seen`" rather than just this one instance —
        // `dismissed` is left responsible only for the write-failed case its
        // own doc comment already describes. No fallback to the unfiltered
        // `archives` here, deliberately: `watch` is always in hand — it is
        // what this map is iterating — so there is nothing for a fallback
        // to cover, and one that read "leave it unfiltered" would fail open
        // the moment a future edit ever made the lookup optional again.
        let visible = watch.findings(in: archives).filter { !dismissed.contains($0.id) }
        return Section(
          login: watch.login, displayName: watch.displayName,
          avatarURL: watch.avatarURL,
          rows: visible.map { archive in
            Row(archive: archive,
                state: ArchiveRowState.state(for: archive, jobs: jobs, file: fileAnswer))
          },
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
        return Section(
          login: watch.login, displayName: watch.displayName,
          avatarURL: watch.avatarURL,
          rows: [], failure: nil, settingsSummary: settingsSummary(for: watch.settings),
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
