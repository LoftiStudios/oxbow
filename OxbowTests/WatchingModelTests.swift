import Foundation
import Testing
import OxbowKit
@testable import Oxbow

@MainActor
@Suite("Watching model")
struct WatchingModelTests {

  private func temporaryStore() -> WatchStore {
    WatchStore(fileURL: URL.temporaryDirectory
      .appending(path: "watching-\(UUID().uuidString)")
      .appending(path: "watches.json"))
  }

  private func watch(
    _ login: String, seen: Set<String> = [],
    settings: Watch.Settings = .init(
      destinationPath: "/Users/x/Downloads", qualityCap: .best,
      output: .videoWithChat, chatSize: .medium),
    downloadsAutomatically: Bool = false
  ) -> Watch {
    Watch(login: login, displayName: login.capitalized,
          settings: settings, downloadsAutomatically: downloadsAutomatically, seen: seen)
  }

  /// A `WatchStore` whose file is actually a directory — `WatchStore.load()`
  /// throws only in this exact shape (a set-aside-worthy decode failure is
  /// recovered internally, so it never propagates), the same trick
  /// `AddChannelModelTests` uses to reach `AddChannelModel.add()`'s own
  /// read-failure branch.
  private func unreadableStore() throws -> WatchStore {
    let file = URL.temporaryDirectory
      .appending(path: "watching-\(UUID().uuidString)")
      .appending(path: "watches.json")
    try FileManager.default.createDirectory(at: file, withIntermediateDirectories: true)
    return WatchStore(fileURL: file)
  }

  private func archive(_ id: String) -> ChannelArchive {
    ChannelArchive(id: id, title: "Stream \(id)", duration: .seconds(3600),
                   publishedAt: Date(timeIntervalSince1970: 0), status: .recorded,
                   thumbnailURL: nil)
  }

  private func model(store: WatchStore) -> WatchingModel {
    WatchingModel(store: store, openIntake: { _, _ in })
  }

  /// A job whose one download step carries `status` and is keyed to `id` via
  /// `mediaIdentifier`, so `ArchiveRowState.state(for:jobs:file:)` sees it as
  /// belonging to the archive with that id. Copies the pattern at
  /// `WatchPollerFailedJobFilterTests.job(_:)`/`step(_:videoID:)` rather than
  /// reaching into `OxbowKitTests`' own helper, which this target cannot see.
  ///
  /// `.done` sets an artifact so a caller can exercise the delivered-file
  /// path too, even though today's two new tests only need `.queued` and
  /// `.running`.
  private func job(_ id: String, _ status: JobStatus) -> Job {
    let stepStatus: StepStatus
    switch status {
    case .queued: stepStatus = .queued
    case .running: stepStatus = .running
    case .done: stepStatus = .done
    case .failed: stepStatus = .failed(StepFailure(kind: .noArtifact, summary: "no artifact"))
    case .cancelled: stepStatus = .cancelled
    }
    let step = Step(
      id: StepID(rawValue: UUID()),
      kind: .downloadVideo(VideoRequest(
        videoID: id, quality: "", destination: URL(filePath: "/out/\(id).mp4"))),
      status: stepStatus,
      artifact: status == .done ? URL(filePath: "/out/\(id).mp4") : nil)
    return Job(id: JobID(rawValue: UUID()), created: Date(timeIntervalSince1970: 0),
               title: "Stream", steps: [step])
  }

  // MARK: - Derivation

  @Test func sectionsMirrorTheSweep() throws {
    let store = temporaryStore()
    try store.save([watch("ninja"), watch("day9tv")])
    let model = model(store: store)
    model.apply([
      .init(login: "ninja", displayName: "Ninja", outcome: .found([archive("1"), archive("2")])),
      .init(login: "day9tv", displayName: "Day9tv", outcome: .found([archive("3")]))])

    #expect(model.sections.map(\.login) == ["ninja", "day9tv"])
    #expect(model.sections[0].rows.map(\.archive.id) == ["1", "2"])
    #expect(model.unreadCount == 3)
  }

  @Test func rowsCarryTheirStateFromTheQueue() throws {
    let store = temporaryStore()
    try store.save([watch("ninja")])
    let model = model(store: store)
    model.apply([.init(login: "ninja", displayName: "Ninja",
                       outcome: .found([archive("1"), archive("2")]))])

    model.updateJobs([job("1", .running)])

    let rows = try #require(model.sections.first?.rows)
    #expect(rows.count == 2)
    #expect(rows.first(where: { $0.id == "1" })?.state == .running)
    #expect(rows.first(where: { $0.id == "2" })?.state == .available)
  }

  /// The rows must not go stale when the queue moves. A job finishing has to
  /// reach the pane without waiting for the next hourly sweep.
  @Test func rowsRefreshWhenTheQueueChanges() throws {
    let store = temporaryStore()
    try store.save([watch("ninja")])
    let model = model(store: store)
    model.apply([.init(login: "ninja", displayName: "Ninja", outcome: .found([archive("1")]))])

    model.updateJobs([job("1", .queued)])
    #expect(model.sections.first?.rows.first?.state == .queued)

    model.updateJobs([job("1", .running)])
    #expect(model.sections.first?.rows.first?.state == .running)
  }

  /// `QueueEngine.publish()` is un-debounced and fires on every helper status
  /// line, so a running download reaches `updateJobs` hundreds of times a
  /// second carrying nothing but a new percentage. `rebuild()` clears the
  /// failure banners, so a refused Add would explain itself for less than a
  /// frame if a progress tick reached it. `submissionFailure` is what pins
  /// that here: surviving one is only possible if no rebuild happened.
  @Test func aProgressTickAloneDoesNotRebuild() async throws {
    let store = temporaryStore()
    try store.save([watch("ninja")])
    let model = WatchingModel(
      store: store, openIntake: { _, _ in },
      queue: { _, _ in "Oxbow could not build that download." })
    model.apply([.init(login: "ninja", displayName: "Ninja", outcome: .found([archive("1")]))])

    // One job, republished — same job id, same step id, same status, a
    // further-along percentage. Exactly what one status line produces.
    let jobID = JobID(rawValue: UUID())
    let stepID = StepID(rawValue: UUID())
    func published(at fraction: Double) -> Job {
      Job(id: jobID, created: Date(timeIntervalSince1970: 0), title: "Stream",
          steps: [Step(
            id: stepID,
            kind: .downloadVideo(VideoRequest(
              videoID: "1", quality: "", destination: URL(filePath: "/out/1.mp4"))),
            status: .running,
            progress: StepProgress(fraction: fraction))])
    }

    model.updateJobs([published(at: 0.1)])
    await model.add(archive("1"), from: "ninja")
    #expect(model.submissionFailure != nil)

    model.updateJobs([published(at: 0.2)])

    #expect(model.submissionFailure != nil, "a percentage is not news to this pane")
    #expect(model.sections[0].rows.first?.state == .running, "and the rows still stand")
  }

  /// The other half of the same guard: a status transition *is* news, and has
  /// to land without waiting for the next sweep.
  @Test func aStatusChangeStillRebuilds() throws {
    let store = temporaryStore()
    try store.save([watch("ninja")])
    let model = model(store: store)
    model.apply([.init(login: "ninja", displayName: "Ninja", outcome: .found([archive("1")]))])

    model.updateJobs([job("1", .queued)])
    #expect(model.sections[0].rows.first?.state == .queued)

    model.updateJobs([job("1", .done)])

    #expect(model.sections[0].rows.first?.state == .downloaded(URL(filePath: "/out/1.mp4")))
  }

  @Test func aFailedChannelKeepsItsReasonAndIsNotCountedAsUnread() throws {
    // Section 7: a failure must read as a failure, never as an empty list.
    let store = temporaryStore()
    try store.save([watch("gone")])
    let model = model(store: store)
    model.apply([.init(login: "gone", displayName: "Gone", outcome: .failed(.noSuchChannel))])

    #expect(model.sections[0].failure != nil)
    #expect(model.sections[0].rows.map(\.archive).isEmpty)
    #expect(model.unreadCount == 0)
  }

  @Test func aChannelWithNothingNewIsNotShownAsAFailure() throws {
    let store = temporaryStore()
    try store.save([watch("quiet")])
    let model = model(store: store)
    model.apply([.init(login: "quiet", displayName: "Quiet", outcome: .found([]))])

    #expect(model.sections[0].failure == nil)
    #expect(model.sections[0].rows.map(\.archive).isEmpty)
  }

  // MARK: - The dismissal overlay

  @Test func ignoringRemovesTheRowImmediately() throws {
    // `WatchPoller.results` is a snapshot taken against the seen-set as it
    // stood at sweep time, so persisting alone would leave the row on screen
    // until the next sweep — up to an hour of a button appearing to do
    // nothing. The overlay is what makes Ignore feel like it worked.
    let store = temporaryStore()
    try store.save([watch("ninja")])
    let model = model(store: store)
    model.apply([.init(login: "ninja", displayName: "Ninja",
                       outcome: .found([archive("1"), archive("2")]))])

    model.ignore(archive("1"), from: "ninja")

    #expect(model.sections[0].rows.map(\.archive).map(\.id) == ["2"])
    #expect(model.unreadCount == 1)
  }

  @Test func ignoringPersistsToTheSeenSet() throws {
    let store = temporaryStore()
    try store.save([watch("ninja")])
    let model = model(store: store)
    model.apply([.init(login: "ninja", displayName: "Ninja", outcome: .found([archive("1")]))])

    model.ignore(archive("1"), from: "ninja")

    #expect(try store.load()[0].seen == ["1"])
  }

  /// The bug: `rebuild()` used to filter a sweep's archives only through the
  /// in-memory `dismissed` overlay, which only ever catches what *this*
  /// model itself wrote through *this* `store`. A seen-set written through a
  /// different `WatchStore` — exactly what `AddChannelModel` does when
  /// Only new re-adds an already-watched channel — left rows on screen the
  /// watch itself already says are seen, for up to an hour until the next
  /// sweep excluded them on its own. No race is needed to reach it: the
  /// watch file already has "1" seen before the very first sweep this test
  /// applies.
  @Test func rebuildAlsoExcludesArchivesTheWatchsOwnSeenSetAlreadyMarks() throws {
    let store = temporaryStore()
    try store.save([watch("ninja", seen: ["1"])])
    let model = model(store: store)

    model.apply([.init(login: "ninja", displayName: "Ninja",
                       outcome: .found([archive("1"), archive("2")]))])

    #expect(
      model.sections[0].rows.map(\.archive).map(\.id) == ["2"],
      "id 1 is already in the watch's own seen set, not just the in-memory overlay")
  }

  @Test func ignoringLeavesWatchesCurrentWithoutACallerHavingToRefresh() throws {
    // `markSeen` used to call `rebuild()` — which re-reads `watches` from
    // disk — before persisting the write, so `watches` reflected the file as
    // it stood a moment earlier and stayed stale until something else
    // rebuilt it. Reading `watches` right here, with no `refresh()` in
    // between, is exactly the trap: a caller (`sections` itself, or
    // `QueueView`'s onEdit before it added its own belt-and-braces call)
    // that trusted this value immediately after Ignore got the channel's old,
    // smaller seen-set.
    let store = temporaryStore()
    try store.save([watch("ninja")])
    let model = model(store: store)
    model.apply([.init(login: "ninja", displayName: "Ninja", outcome: .found([archive("1")]))])

    model.ignore(archive("1"), from: "ninja")

    #expect(model.watches.first(where: { $0.login == "ninja" })?.seen == ["1"])
  }

  @Test func addingQueuesItWithTheChannelsSettingsAndOpensNothing() async throws {
    let store = temporaryStore()
    let capped = watch("ninja")
    try store.save([capped])
    let opened = OpenedBox()
    let queued = QueuedBox()
    let model = WatchingModel(
      store: store,
      openIntake: { archive, _ in opened.id = archive.id },
      queue: { archive, watch in
        queued.id = archive.id
        queued.settings = watch.settings
        return nil
      })
    model.apply([.init(login: "ninja", displayName: "Ninja", outcome: .found([archive("1")]))])

    await model.add(archive("1"), from: "ninja")

    // The whole point of the change: it queues, using settings frozen onto
    // the watch, and no form opens to ask for them a second time.
    #expect(queued.id == "1")
    #expect(queued.settings == capped.settings)
    #expect(opened.id == nil, "the primary action must not open intake")
    #expect(try store.load()[0].seen == ["1"])
    // This injected queue only records — it publishes no job — so the
    // archive ends up seen with nothing in the queue for it, and a row like
    // that is hidden. The real path always leaves a job behind; that is
    // `addingLeavesTheRowInPlaceAsQueuedOnceItsJobExists` below.
    #expect(model.sections[0].rows.map(\.archive).isEmpty)
  }

  /// **The transition this stage exists to deliver.** `add` queues first and
  /// marks seen second, so for one instant the archive is both dismissed and
  /// queued — and it has to stay on screen, reading "In queue", rather than
  /// leaving the list at the moment a person asked for it. The job is what
  /// keeps it there, exactly as the real engine's publication does: this
  /// closure publishes from inside the submission, which is where
  /// `QueueEngine` publishes too.
  @Test func addingLeavesTheRowInPlaceAsQueuedOnceItsJobExists() async throws {
    let store = temporaryStore()
    try store.save([watch("ninja")])
    let held = ModelBox()
    let queued = job("1", .queued)
    let model = WatchingModel(
      store: store, openIntake: { _, _ in },
      queue: { _, _ in
        held.model?.updateJobs([queued])
        return nil
      })
    held.model = model
    model.apply([.init(login: "ninja", displayName: "Ninja", outcome: .found([archive("1")]))])

    await model.add(archive("1"), from: "ninja")

    #expect(try store.load()[0].seen == ["1"], "queueing still marks it seen")
    let rows = try #require(model.sections.first?.rows)
    #expect(rows.map(\.archive.id) == ["1"], "a queued archive stays listed once it is seen")
    #expect(rows.first?.state == .queued)
  }

  /// A job outranks the watch's own persisted `seen`, not only the in-memory
  /// `dismissed` overlay — `WatchPoller.markSubmitted` writes `seen` through
  /// a different `WatchStore` the moment it queues an automatic download, so
  /// an archive can be seen on disk with a job this model never watched
  /// being made.
  @Test func anArchiveSeenOnDiskIsStillShownWhileTheQueueHoldsAJobForIt() throws {
    let store = temporaryStore()
    try store.save([watch("ninja", seen: ["1", "2"])])
    let model = model(store: store)
    model.apply([.init(login: "ninja", displayName: "Ninja",
                       outcome: .found([archive("1"), archive("2")]))])

    model.updateJobs([job("1", .done)])

    let rows = try #require(model.sections.first?.rows)
    #expect(rows.map(\.archive.id) == ["1"], "id 2 is seen with no job, so it stays hidden")
    #expect(rows.first?.state == .downloaded(URL(filePath: "/out/1.mp4")))
  }

  /// Losing a job costs the row its place — the lease §7.2 of
  /// `channel-history.md` calls this stage's scaffolding — and costs the
  /// archive nothing else. `seen` is untouched, because deriving it from the
  /// queue is exactly what `channel-watching.md` §4 forbids: a job someone
  /// cleared out would otherwise license a second download.
  @Test func removingAJobHidesTheRowWithoutUnmarkingTheArchive() throws {
    let store = temporaryStore()
    try store.save([watch("ninja", seen: ["1"])])
    let model = model(store: store)
    model.apply([.init(login: "ninja", displayName: "Ninja", outcome: .found([archive("1")]))])
    model.updateJobs([job("1", .done)])
    #expect(model.sections[0].rows.count == 1)

    model.updateJobs([])

    #expect(model.sections[0].rows.isEmpty)
    #expect(try store.load()[0].seen == ["1"], "the seen-set never follows the queue")
  }

  /// A refusal leaves the row exactly where it was. Marking it seen would
  /// bury an archive nothing is downloading, which is the failure §6.3 calls
  /// out — reached here before a job ever exists rather than after one fails.
  @Test func aRefusedAddSaysWhyAndLeavesTheRowAlone() async throws {
    let store = temporaryStore()
    try store.save([watch("ninja")])
    let model = WatchingModel(
      store: store, openIntake: { _, _ in },
      queue: { _, _ in "Oxbow could not build that download." })
    model.apply([.init(login: "ninja", displayName: "Ninja", outcome: .found([archive("1")]))])

    await model.add(archive("1"), from: "ninja")

    #expect(model.submissionFailure == "Oxbow could not build that download.")
    #expect(try store.load()[0].seen.isEmpty, "a refusal must not mark it handled")
    #expect(model.sections[0].rows.map(\.archive).count == 1, "the row has to stay actionable")
  }

  @Test func openingInIntakeHandsItOffAndMarksItSeen() throws {
    let store = temporaryStore()
    try store.save([watch("ninja")])
    let opened = OpenedBox()
    let model = WatchingModel(store: store, openIntake: { archive, _ in opened.id = archive.id })
    model.apply([.init(login: "ninja", displayName: "Ninja", outcome: .found([archive("1")]))])

    model.openInIntake(archive("1"), from: "ninja")

    #expect(opened.id == "1")
    // Seen on open, not on the eventual download: someone who opens the form
    // and cancels has still answered the question the row was asking.
    #expect(try store.load()[0].seen == ["1"])
    #expect(model.sections[0].rows.map(\.archive).isEmpty)
  }

  /// The exact shape `OxbowApp` wires in production — its `openIntake`
  /// closure only ever builds a `PendingIntake` from the watch `add` hands it,
  /// never from `Preferences`. `addingPersistsAndOpensIntake` above only pins
  /// the archive id; this pins the other half of the hand-off, that a channel
  /// someone capped at 720p, video-only actually carries those settings to
  /// intake rather than whatever the global defaults happen to be.
  @Test func addHandsIntakeTheWatchsFrozenSettingsNotGlobalPreferences() throws {
    let store = temporaryStore()
    let capped = Watch(
      login: "ninja", displayName: "Ninja",
      settings: .init(
        destinationPath: "/Users/x/Archive", qualityCap: .p720,
        output: .video, chatSize: .large),
      downloadsAutomatically: false, seen: [])
    try store.save([capped])

    var pending: PendingIntake?
    let model = WatchingModel(store: store, openIntake: { archive, watch in
      pending = PendingIntake(archiveID: archive.id, settings: watch.settings)
    })
    model.apply([.init(login: "ninja", displayName: "Ninja", outcome: .found([archive("1")]))])

    model.openInIntake(archive("1"), from: "ninja")

    let handedOff = try #require(pending)
    #expect(handedOff.archiveID == "1")
    #expect(handedOff.settings == capped.settings)
  }

  @Test func anActionOnAnUnknownChannelIsIgnoredRatherThanCrashing() throws {
    // The watch file can change under us — a later stage will let someone
    // remove a channel while findings from it are still on screen.
    let store = temporaryStore()
    try store.save([watch("ninja")])
    let model = model(store: store)
    model.apply([.init(login: "removed", displayName: "Removed",
                       outcome: .found([archive("1")]))])

    model.ignore(archive("1"), from: "removed")

    #expect(try store.load().map(\.login) == ["ninja"])
  }

  // MARK: - markSeen refuses loudly on an unreadable store

  /// The bug: `dismissed.insert(id)` already hides the row before `markSeen`
  /// ever touches the store, so an unreadable `watches.json` used to fail
  /// completely silently — the row vanished, `add(_:from:)` opened no
  /// intake window, and nothing on screen said why. The other three writers
  /// of `watches.json` (`AddChannelModel.add()` in both modes, and
  /// `stopWatching`) all refuse loudly on the identical condition; this pins
  /// `markSeen`'s own turn to do the same, for both call shapes.
  @Test func ignoringOnAnUnreadableStoreSurfacesTheFailureRatherThanFailingSilently() throws {
    let store = try unreadableStore()
    defer { try? FileManager.default.removeItem(at: store.fileURL.deletingLastPathComponent()) }
    let model = model(store: store)

    model.ignore(archive("1"), from: "ninja")

    #expect(model.markSeenFailure != nil, "the refusal must say why, not just vanish")
  }

  @Test func addingOnAnUnreadableStoreSurfacesTheFailureAndQueuesNothing() async throws {
    let store = try unreadableStore()
    defer { try? FileManager.default.removeItem(at: store.fileURL.deletingLastPathComponent()) }
    let opened = OpenedBox()
    let queued = QueuedBox()
    let model = WatchingModel(
      store: store, openIntake: { archive, _ in opened.id = archive.id },
      queue: { archive, _ in queued.id = archive.id; return nil })

    await model.add(archive("1"), from: "ninja")

    #expect(opened.id == nil, "no watch to hand to intake means no window should open")
    #expect(queued.id == nil, "a watch that cannot be read cannot compose a job")
    #expect(model.markSeenFailure != nil, "the refusal must say why, not just vanish")
  }

  /// A `WatchStore` whose directory reads fine but cannot be written to.
  /// `load()` neither writes nor needs write access, so it keeps succeeding;
  /// `save()` fails at its very first write (`data.write(to: scratch)`,
  /// creating the scratch file the atomic replace needs) because the
  /// directory itself has no write bit. That is the split this needs:
  /// `unreadableStore()` above makes `load()` itself throw, which is
  /// `markSeen`'s *other* failure branch — this one is behind `try?
  /// store.save`, the one that used to swallow the error with nothing on
  /// screen to show for it.
  private func writeProtectedStore(seeding watches: [Watch]) throws -> WatchStore {
    let dir = URL.temporaryDirectory.appending(path: "watching-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let store = WatchStore(fileURL: dir.appending(path: "watches.json"))
    // Seed while the directory is still writable — `store.save` below is the
    // one write this test wants to survive.
    try store.save(watches)
    // 0o500 (r-x) keeps read and traversal, so the existing `watches.json`
    // stays fully readable, but drops write, so nothing new can be created
    // in the directory — including the scratch file `save()` writes before
    // its atomic replace.
    try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: dir.path)
    return store
  }

  /// The regression: `rebuild()` now reconciles `dismissed` against every
  /// watch's own persisted `seen` (the correct fix that lets a failed
  /// download's archive return to the inbox in the same session — see
  /// `aFailedDownloadsArchiveReappearsInTheSameSessionOnceTheWatchForgetsIt`
  /// above). That reconciliation reads `seen` fresh off disk on every
  /// `rebuild()`, including the one `markSeen` runs on its own failure path —
  /// so when `store.save` fails silently (`try?`), the id never actually
  /// lands in `seen`, and `markSeenFailure` was never set for this branch
  /// (only the `store.load()` throw above set it). Ignore or Add on a channel
  /// whose persist fails used to look like nothing happened at all: no
  /// message, and nothing to tell it apart from a completed action.
  ///
  /// **Confirming this exercises the save branch, not the load branch:**
  /// unlike `unreadableStore()`, `store.load()` against this fixture must
  /// keep succeeding throughout — asserted directly below, both before
  /// `ignore()` runs and after, the second one also pinning that "1" never
  /// actually made it into `seen` (proof the save itself failed, not that it
  /// silently succeeded).
  @Test func ignoringOnAWriteProtectedStoreSurfacesTheSaveFailureRatherThanFailingSilently() throws {
    let store = try writeProtectedStore(seeding: [watch("ninja")])
    let dir = store.fileURL.deletingLastPathComponent()
    defer {
      // Restore the write bit before cleanup — `removeItem` on a read-only
      // directory would itself fail and leak the fixture.
      try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
      try? FileManager.default.removeItem(at: dir)
    }
    // Confirms `load()` still works against this fixture — a store that
    // could not be read at all would reach `markSeen`'s *other* failure
    // branch instead, the one `ignoringOnAnUnreadableStoreSurfacesTheFailure
    // RatherThanFailingSilently` above already covers.
    #expect(try store.load().map(\.login) == ["ninja"], "precondition: load must still succeed")

    let model = model(store: store)
    model.apply([.init(login: "ninja", displayName: "Ninja", outcome: .found([archive("1")]))])

    model.ignore(archive("1"), from: "ninja")

    #expect(model.markSeenFailure != nil, "a failed save must say why, not just vanish")
    #expect(
      try store.load()[0].seen.isEmpty,
      "the save must have actually failed — \"1\" never reached seen on disk")
  }

  @Test func aSweepThatStraddlesADismissalDoesNotBringTheRowBack() throws {
    // `sweep` reads the seen-set once up front, then makes slow sequential
    // per-channel calls. A sweep that was already in flight when the ignore
    // landed finishes with results computed before that write — still
    // containing the just-dismissed archive. An identical payload reapplied
    // is exactly that case, and the row must stay gone rather than reappear.
    let store = temporaryStore()
    try store.save([watch("ninja")])
    let model = model(store: store)
    model.apply([.init(login: "ninja", displayName: "Ninja", outcome: .found([archive("1")]))])
    model.ignore(archive("1"), from: "ninja")

    model.apply([.init(login: "ninja", displayName: "Ninja", outcome: .found([archive("1")]))])

    #expect(model.sections[0].rows.map(\.archive).isEmpty)
  }

  @Test func aDismissalDropsOutOfTheOverlayButTheArchiveStaysHiddenViaTheWatchsOwnSeenSet() throws {
    // A sweep computed after the write no longer carries the dismissed id at
    // all, so it drops out of the `dismissed` overlay safely — that set
    // stays bounded instead of growing forever, rather than accumulating
    // every id ever acted on for the life of the app.
    //
    // **Before finding 3's fix, that alone made a later sweep that happened
    // to reuse the same id show it as brand new** — `dismissed` was the
    // *only* thing hiding it. Now `rebuild()` also reconciles against the
    // watch's own `seen` set (`Watch.findings(in:)`), which `ignore()`
    // already committed this id to when it persisted — so the row must stay
    // hidden regardless of what `dismissed` has since forgotten.
    // `dismissed` is left responsible only for the write-failed case its own
    // doc comment describes.
    let store = temporaryStore()
    try store.save([watch("ninja")])
    let model = model(store: store)
    model.apply([.init(login: "ninja", displayName: "Ninja", outcome: .found([archive("1")]))])
    model.ignore(archive("1"), from: "ninja")

    model.apply([.init(login: "ninja", displayName: "Ninja", outcome: .found([]))])
    model.apply([.init(login: "ninja", displayName: "Ninja", outcome: .found([archive("1")]))])

    #expect(
      model.sections[0].rows.map(\.archive).isEmpty,
      "the watch's own seen set still hides it, even once dismissed has forgotten it")
  }

  /// Finding 5. A manual Add persists the archive into `seen` *and* into
  /// `dismissed` together (`markSeen`). If that download later fails,
  /// `AutoDownloadObserver.forget` un-marks it on disk, through a different
  /// `WatchStore` over the same file — but `dismissed` never hears about
  /// that; it only narrows itself in `apply(_:)` against a sweep's *found*
  /// ids, and the archive is still found (it has not expired). Before this
  /// fix, the row stayed hidden here regardless — reappearing only after a
  /// relaunch threw `dismissed` away, which is exactly what Task 4's own
  /// test could not catch, since it exercises the observer in isolation
  /// rather than through this model's overlay.
  @Test func aFailedDownloadsArchiveReappearsInTheSameSessionOnceTheWatchForgetsIt() async throws {
    let store = temporaryStore()
    try store.save([watch("ninja")])
    let model = model(store: store)
    model.apply([.init(login: "ninja", displayName: "Ninja", outcome: .found([archive("1")]))])

    await model.add(archive("1"), from: "ninja")
    #expect(model.sections[0].rows.map(\.archive).isEmpty, "precondition: Add hid the row and marked it seen")

    // Stands in for `AutoDownloadObserver.forget`: the job for "1" failed,
    // so it is un-marked on disk through a second `WatchStore` instance over
    // the same file — out of band, with nobody looking.
    var current = try store.load()
    current[0] = current[0].forgetting(["1"])
    try store.save(current)

    // A later sweep still finds "1" — it has not expired — and republishes
    // the identical payload.
    model.apply([.init(login: "ninja", displayName: "Ninja", outcome: .found([archive("1")]))])

    #expect(
      model.sections[0].rows.map(\.archive).map(\.id) == ["1"],
      "a failed download's archive must return to the inbox in this session, not only after relaunch")
  }

  // MARK: - Every watched channel gets a section

  @Test func aChannelNeverPolledStillGetsASectionWithItsSettings() throws {
    // Today: a channel with nothing in `latest` does not appear at all. The
    // model has to load the watch list itself, not only wait for a sweep,
    // or a channel added a moment ago is invisible until the poller catches
    // up to it — which can be minutes away (`WatchingView.isSweeping`'s own
    // doc comment).
    let store = temporaryStore()
    try store.save([watch("ninja",
      settings: .init(destinationPath: "/Users/x/Downloads", qualityCap: .best,
                      output: .videoWithChat, chatSize: .medium))])
    let model = model(store: store)

    #expect(model.sections.map(\.login) == ["ninja"])
    #expect(model.sections[0].rows.map(\.archive).isEmpty)
    #expect(model.sections[0].failure == nil)
    #expect(model.sections[0].settingsSummary
      == "Video + chat · Best available · Medium chat · Downloads")
  }

  @Test func twoChannelsWithDifferentSettingsShowTheirOwnSummaries() throws {
    let store = temporaryStore()
    try store.save([
      watch("ninja", settings: .init(
        destinationPath: "/Users/x/Downloads", qualityCap: .best,
        output: .videoWithChat, chatSize: .medium)),
      watch("day9tv", settings: .init(
        destinationPath: "/Users/x/Archive", qualityCap: .p720,
        output: .video, chatSize: .large)),
    ])
    let model = model(store: store)

    let summaries = Dictionary(uniqueKeysWithValues: model.sections.map { ($0.login, $0.settingsSummary) })
    #expect(summaries["ninja"] == "Video + chat · Best available · Medium chat · Downloads")
    // Chat size is withheld when the output does not include chat, matching
    // `IntakeModel.withholdsChatSizeFromSave` — a chat-less watch has no
    // chat size to show.
    #expect(summaries["day9tv"] == "Video · Up to 720p · Archive")
  }

  @Test func automaticDownloadingIsVisibleOnTheSectionWhenItIsOn() throws {
    let store = temporaryStore()
    try store.save([
      watch("ninja", downloadsAutomatically: true),
      watch("day9tv", downloadsAutomatically: false),
    ])
    let model = model(store: store)

    let automatic = Dictionary(
      uniqueKeysWithValues: model.sections.map { ($0.login, $0.downloadsAutomatically) })
    #expect(automatic["ninja"] == true)
    #expect(automatic["day9tv"] == false)
  }

  // MARK: - Stopping a watch

  @Test func stopWatchingRemovesTheWatchAndPersistsPreservingOthers() throws {
    let store = temporaryStore()
    try store.save([watch("ninja"), watch("day9tv")])
    let model = model(store: store)
    model.apply([
      .init(login: "ninja", displayName: "Ninja", outcome: .found([archive("1")])),
      .init(login: "day9tv", displayName: "Day9tv", outcome: .found([archive("2")]))])

    model.stopWatching("ninja")

    #expect(try store.load().map(\.login) == ["day9tv"])
    // Gone immediately, not just on the next sweep — `ninja`'s own row from
    // the sweep just applied must not linger because `latest` still carries
    // it (see `stopWatching`'s own doc comment).
    #expect(model.sections.map(\.login) == ["day9tv"])
    #expect(model.stopWatchingFailure == nil)
  }

  @Test func aSweepThatStraddlesAStopDoesNotResurrectTheStoppedChannel() throws {
    // `WatchPoller.sweep` is sequential and can run for minutes, so a sweep
    // already in flight when Stop Watching runs can still land afterwards —
    // via `apply(_:)`, which replaces `latest` wholesale — still carrying
    // the stopped channel's own entry. Reapplying the identical sweep here
    // stands in for exactly that stale landing, and the row must stay gone
    // rather than come back until the next real sweep excludes it on its
    // own (the same class of bug `aSweepThatStraddlesADismissalDoesNotBring
    // TheRowBack` guards against for Ignore).
    let store = temporaryStore()
    try store.save([watch("ninja"), watch("day9tv")])
    let model = model(store: store)
    let sweep = [
      WatchPollResult(login: "ninja", displayName: "Ninja", outcome: .found([archive("1")])),
      WatchPollResult(login: "day9tv", displayName: "Day9tv", outcome: .found([archive("2")])),
    ]
    model.apply(sweep)

    model.stopWatching("ninja")
    // The in-flight sweep lands after the stop, unchanged.
    model.apply(sweep)

    #expect(model.sections.map(\.login) == ["day9tv"])
  }

  @Test func stoppingAChannelDropsItsOwnDismissedIdsSoAReAddDoesNotHideThem() throws {
    // A stopped channel gets no more sweeps to let `apply`'s own
    // `formIntersection` drop its ids out of the overlay — left alone, they
    // would linger forever, and a later re-add whose first sweep reuses one
    // of those VOD ids would have a genuinely new archive hidden by a
    // dismissal earned by a watch that no longer exists.
    //
    // **Through `refresh()`, not a fresh `apply(_:)`** — re-sweeping after
    // the re-add would mask the exact bug this pins: `latest` still holds
    // the *original* sweep's entry for "1" throughout (untouched by
    // `stopWatching`, see its own comment), so the only thing standing
    // between that entry and the row it should now show again is whether
    // `dismissed` still contains "1". `refresh()` is what production calls
    // once the re-add's window closes, and the next real sweep can be up to
    // an hour away.
    let store = temporaryStore()
    try store.save([watch("ninja")])
    let model = model(store: store)
    model.apply([.init(login: "ninja", displayName: "Ninja", outcome: .found([archive("1")]))])
    model.ignore(archive("1"), from: "ninja")

    model.stopWatching("ninja")
    try store.save([watch("ninja")])
    model.refresh()

    #expect(model.sections.first(where: { $0.login == "ninja" })?.rows.map(\.archive).map(\.id) == ["1"])
  }

  // MARK: - Re-reading the watch list on demand

  @Test func refreshShowsAChannelAddedToTheStoreAfterConstruction() throws {
    // `AddChannelModel` writes through its own `WatchStore`, a different
    // instance from the one this model reads through — nothing here notices
    // that write on its own. Without `refresh()`, a channel added from that
    // window stays invisible until the next hourly sweep, which is the exact
    // flow the Watching pane's toolbar button exists for appearing to do
    // nothing.
    let store = temporaryStore()
    try store.save([watch("ninja")])
    let model = model(store: store)
    #expect(model.sections.map(\.login) == ["ninja"])

    try store.save([watch("ninja"), watch("day9tv")])
    model.refresh()

    #expect(model.sections.map(\.login).sorted() == ["day9tv", "ninja"])
  }

  @Test func stopWatchingRefusesRatherThanOverwritingWhenTheStoreCannotBeRead() throws {
    // The same bug `AddChannelModelTests
    // .addRefusesRatherThanOverwritingWhenTheWatchListCannotBeRead` guards
    // against: a `try? store.load() ?? []` here would read the unreadable
    // file as "nothing is watched" and save a filtered list over it,
    // permanently losing every channel this call was never asked to touch.
    let store = try unreadableStore()
    defer { try? FileManager.default.removeItem(at: store.fileURL.deletingLastPathComponent()) }
    let model = model(store: store)

    model.stopWatching("ninja")

    #expect(model.stopWatchingFailure != nil, "the refusal must say why, not just dismiss")
    var isDirectory: ObjCBool = false
    let stillThere = FileManager.default.fileExists(
      atPath: store.fileURL.path, isDirectory: &isDirectory)
    #expect(stillThere && isDirectory.boolValue, "must refuse rather than save over what it could not read")
  }

  // MARK: - stopWatchingFailure is cleared at the right moments

  /// The bug: `stopWatchingFailure` used to clear only on a *later
  /// successful stop* — of any channel — which cut both ways. It survived a
  /// pane switch or an unrelated Ignore/Add indefinitely (nothing else ever
  /// touched it), yet a successful stop of a *different* channel cleared it
  /// while the login that actually failed was still watched, implying the
  /// problem had been resolved when it had not. `rebuild()` now clears it on
  /// every path that reaches it (`refresh()`, `apply(_:)`, `markSeen`, and a
  /// later `stopWatching` of any channel) — an honest "something else has
  /// happened since" rather than a specific, misleading claim.
  @Test func stopWatchingFailureIsClearedByAnyLaterActionNotJustAMatchingStop() throws {
    let file = URL.temporaryDirectory
      .appending(path: "watching-\(UUID().uuidString)")
      .appending(path: "watches.json")
    try FileManager.default.createDirectory(at: file, withIntermediateDirectories: true)
    let store = WatchStore(fileURL: file)
    let model = model(store: store)

    model.stopWatching("ninja")
    #expect(model.stopWatchingFailure != nil, "precondition: the refusal is visible")

    // Fixes the underlying store and takes some other, unrelated action —
    // standing in for switching away from the Watching pane and back, since
    // `refresh()` is what that re-appearance calls.
    try FileManager.default.removeItem(at: file)
    try store.save([watch("day9tv")])
    model.refresh()

    #expect(
      model.stopWatchingFailure == nil,
      "a later, unrelated action must not leave a stale refusal on screen indefinitely")
  }

  // MARK: - The class invariant, under random interleaving

  /// Both existing race tests (`aSweepThatStraddlesADismissalDoesNotBring
  /// TheRowBack`, `aSweepThatStraddlesAStopDoesNotResurrectTheStoppedChannel`)
  /// fake staleness by re-applying an *identical* payload — which pins one
  /// instance of the bug, not the property the class is supposed to have.
  /// This drives `apply`, `ignore`, `add`, `stopWatching`, `refresh`, and a
  /// write through a second `WatchStore` (standing in for `AddChannelModel`
  /// writing the same file) in a random order, and checks two things after
  /// *every* step rather than only at the end:
  ///
  /// 1. `sections` and `watches` name exactly the same logins — no section
  ///    for a channel that is not watched, no watched channel missing one.
  /// 2. A watched channel's archives are exactly its newest sweep's findings,
  ///    minus whatever its own persisted `seen` set has since gained.
  ///
  /// Deliberately does not inject a failed store write anywhere in the
  /// interleaving — that path (`dismissed`'s one remaining job) already has
  /// its own dedicated tests above. Every write here succeeds, so invariant 2
  /// never has to account for "pending a failed write" to hold.
  @Test func watchesIsAlwaysTheSpineUnderRandomInterleaving() async throws {
    let seed: UInt64 = 0x5EED_C0FFEE
    var rng = SeededGenerator(seed: seed)

    let store = temporaryStore()
    let loginPool = ["ninja", "day9tv", "asmongold"]
    // Scoped per login, deliberately: real Twitch archive ids are unique
    // platform-wide, so two different channels never share one. `dismissed`
    // is not scoped by login (it never has been — see its own doc comment),
    // and sharing one raw id pool across logins here would manufacture
    // cross-channel id collisions no real sweep could ever produce, hiding
    // one channel's finding behind an unrelated channel's dismissal for a
    // reason that has nothing to do with the property this test checks.
    func ids(for login: String) -> [String] { (1...4).map { "\(login)-\($0)" } }

    try store.save([watch("ninja"), watch("day9tv")])
    let model = model(store: store)

    // This test's own record of what the last sweep actually handed
    // `apply(_:)` for each login — the ground truth invariant 2 checks
    // against. Never cleared by a stop: a real `latest` array is not either
    // (see `WatchingModel.stopWatching`'s own comment), so a channel that is
    // stopped and re-added is checked against the same stale sweep the model
    // itself would still be holding.
    var lastFound: [String: [ChannelArchive]] = [:]
    var lastFailed: Set<String> = []

    func currentLogins() throws -> [String] { try store.load().map(\.login) }

    func performSweep() throws {
      // One `apply(_:)` call for every currently watched login, exactly the
      // shape `WatchPoller.sweep` produces — never one call per login.
      // `dismissed.formIntersection(found)` inside `apply(_:)` only narrows
      // against the ids the *whole* array carries; splitting this into one
      // call per login would starve that intersection of every other
      // login's ids on each call and shrink `dismissed` for reasons that
      // have nothing to do with a real sweep.
      //
      // Mirrors `WatchPoll.sweep` in the other respect too: a raw fetch per
      // login, immediately narrowed through that login's *own*
      // `findings(in:)` — against whatever `seen` was at this exact moment
      // — before the result ever reaches `apply(_:)`. `lastFound` records
      // that *carried*, already-narrowed list, not the raw fetch: "the
      // newest sweep carries it" is about what the sweep actually reported,
      // and a later re-add with a fresh, emptied `seen` cannot retroactively
      // widen what an earlier, now-stale sweep once said. That is exactly
      // the asymmetry the sixth bug turned on, so the ground truth here has
      // to preserve it.
      var results: [WatchPollResult] = []
      for watchEntry in try store.load() {
        if Bool.random(using: &rng) {
          let raw = ids(for: watchEntry.login).filter { _ in Bool.random(using: &rng) }.map(archive)
          let carried = watchEntry.findings(in: raw)
          results.append(.init(login: watchEntry.login, displayName: watchEntry.displayName,
                               outcome: .found(carried)))
          lastFound[watchEntry.login] = carried
          lastFailed.remove(watchEntry.login)
        } else {
          results.append(.init(login: watchEntry.login, displayName: watchEntry.displayName,
                               outcome: .failed(.noSuchChannel)))
          lastFailed.insert(watchEntry.login)
        }
      }
      // `apply(_:)` sets `latest = results` — wholesale, not merged (its own
      // doc comment) — so a login this sweep does not cover (because it was
      // unwatched when `WatchPoll.sweep` ran) loses its entry outright, not
      // only until a later sweep adds it back. A completely stale entry
      // surviving *through* a real sweep that had every chance to refresh it
      // is not what "the newest sweep carries it" means; the ground truth
      // has to go stale the same way `latest` actually does.
      let covered = Set(results.map(\.login))
      for login in lastFound.keys where !covered.contains(login) { lastFound[login] = nil }
      lastFailed.formIntersection(covered)
      model.apply(results)
    }

    func performIgnoreOrAdd() async throws {
      guard let login = try currentLogins().randomElement(using: &rng),
            let id = ids(for: login).randomElement(using: &rng)
      else { return }
      if Bool.random(using: &rng) {
        model.ignore(archive(id), from: login)
      } else {
        await model.add(archive(id), from: login)
      }
    }

    func performStop() throws {
      guard let login = try currentLogins().randomElement(using: &rng) else { return }
      model.stopWatching(login)
    }

    func performForeignWrite() throws {
      // Stands in for `AddChannelModel` writing `watches.json` through its
      // own, separate `WatchStore` instance. Only ever adds — the model's
      // own doc comment is explicit that `WatchingModel` is "the only writer"
      // that ever *removes* a watch (`stopWatching`, which is also the only
      // place that cleans `dismissed` of a removed watch's ids); a foreign
      // write pruning some other channel here would be testing a shape
      // `AddChannelModel` never actually takes; `stopWatching` above is the
      // only removal path this interleaving needs to cover.
      let foreign = WatchStore(fileURL: store.fileURL)
      var current = try foreign.load()
      if let addable = loginPool.first(where: { candidate in
        !current.contains { $0.login == candidate }
      }) {
        current.append(watch(addable))
        try foreign.save(current)
      }
    }

    func checkInvariants(step: Int) throws {
      let watchedLogins = Set(model.watches.map(\.login))
      #expect(Set(model.sections.map(\.login)) == watchedLogins,
        "seed \(seed) step \(step): sections must name exactly the watched logins")

      for watchEntry in model.watches {
        let expectedIDs: Set<String>
        if lastFailed.contains(watchEntry.login) {
          expectedIDs = []
        } else if let carried = lastFound[watchEntry.login] {
          expectedIDs = Set(carried.map(\.id)).subtracting(watchEntry.seen)
        } else {
          expectedIDs = []
        }
        let actualIDs = Set(
          model.sections.first(where: { $0.login == watchEntry.login })?.rows.map(\.archive).map(\.id) ?? [])
        #expect(actualIDs == expectedIDs,
          "seed \(seed) step \(step) login \(watchEntry.login): archives must be exactly the newest sweep's findings minus seen")
      }
    }

    try checkInvariants(step: 0)
    for step in 1...300 {
      switch Int.random(in: 0..<6, using: &rng) {
      case 0, 1: try performSweep()
      case 2, 3: try await performIgnoreOrAdd()
      case 4: try performStop()
      default: try performForeignWrite()
      }
      // `refresh()` is folded in here rather than its own case so a stray
      // `AddChannelModel`-shaped write always gets picked up promptly, the
      // same as production wiring it to the window closing.
      if step.isMultiple(of: 7) { model.refresh() }
      try checkInvariants(step: step)
    }
  }

  /// The sixth bug, confirmed live. `stopWatching` used to remove the login's
  /// own entry from `latest` outright — irreversible — while `stoppedLogins`
  /// (a reversible tombstone `refreshWatches()` lifted the moment the login
  /// was back in the file) guarded the same race with the opposite lifetime.
  /// Re-adding a stopped channel lifted the reversible guard and exposed the
  /// irreversible one: the channel's own last-known findings were gone for
  /// good, so it fell into the never-polled branch — `archives: []`,
  /// `failure: nil` — reading as "nothing new" when the re-add (with "All
  /// available") asked for the whole back catalogue.
  ///
  /// **Through `refresh()`, not `apply(_:)`.** `stoppingAChannelDropsItsOwn
  /// DismissedIdsSoAReAddDoesNotHideThem` above walks the same sequence but
  /// recovers by re-applying the sweep — a path production never takes after
  /// a re-add; the window closing calls `refresh()` (see `OxbowApp`), and the
  /// next real sweep is up to an hour away. This is the sequence that
  /// actually happens.
  @Test func reAddingAStoppedChannelAndRefreshingShowsItsLastFindingsAgain() throws {
    let store = temporaryStore()
    try store.save([watch("ninja")])
    let model = model(store: store)
    model.apply([.init(login: "ninja", displayName: "Ninja",
                       outcome: .found([archive("1"), archive("2")]))])

    model.stopWatching("ninja")
    // Re-add with "All available" — a fresh `Watch` with an empty `seen`,
    // the same shape `AddChannelModel.add(_:)` writes for that scope.
    try store.save([watch("ninja")])
    model.refresh()

    #expect(
      model.sections.first(where: { $0.login == "ninja" })?.rows.map(\.archive).map(\.id).sorted()
        == ["1", "2"],
      "the re-added channel's own last sweep must still be there once it is watched again")
  }

  /// The avatar has to reach the view through `Section`, since
  /// `WatchingView` never sees a `Watch`.
  @Test func aSectionCarriesItsChannelsAvatarURL() throws {
    let store = temporaryStore()
    var withAvatar = watch("ninja")
    withAvatar.avatarURL = URL(string: "https://example.com/a-300x300.png")
    try store.save([withAvatar])
    let model = model(store: store)

    #expect(model.sections.first?.avatarURL?.absoluteString.hasSuffix("300x300.png") == true)
  }

  /// A channel added before `avatarURL` existed still gets a section; the
  /// view shows a placeholder, and nothing backfills the URL.
  @Test func aSectionWithoutAnAvatarIsNotAnError() throws {
    let store = temporaryStore()
    try store.save([watch("ninja")])
    let model = model(store: store)

    #expect(model.sections.count == 1)
    #expect(model.sections.first?.avatarURL == nil)
  }
}

/// A tiny deterministic PRNG so a failure found by chance is reproducible —
/// `SystemRandomNumberGenerator` cannot be seeded, and reproducing exactly
/// the interleaving that broke the invariant is the entire point of fuzzing
/// it. (splitmix64.)
private struct SeededGenerator: RandomNumberGenerator {
  private var state: UInt64
  init(seed: UInt64) { state = seed == 0 ? 0xdeadbeef : seed }
  mutating func next() -> UInt64 {
    state &+= 0x9E37_79B9_7F4A_7C15
    var z = state
    z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
    z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
    return z ^ (z >> 31)
  }
}

/// A reference box so an escaping closure's effect is observable from a test.
@MainActor private final class OpenedBox {
  var id: String?
}

/// What the injected `queue` closure was asked to submit.
@MainActor private final class QueuedBox {
  var id: String?
  var settings: Watch.Settings?
}

/// Lets an injected closure reach the model that owns it, so a test can
/// publish a job from inside a submission the way the real engine does.
@MainActor private final class ModelBox {
  var model: WatchingModel?
}
