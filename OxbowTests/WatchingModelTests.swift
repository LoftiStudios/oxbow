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
    downloadsAutomatically: Bool = false,
    avatarURL: URL? = nil
  ) -> Watch {
    Watch(login: login, displayName: login.capitalized,
          settings: settings, downloadsAutomatically: downloadsAutomatically, seen: seen,
          avatarURL: avatarURL)
  }

  /// A directory at the watch-file path forces a read error; decode failures are recovered
  /// internally.
  private func unreadableStore() throws -> WatchStore {
    let file = URL.temporaryDirectory
      .appending(path: "watching-\(UUID().uuidString)")
      .appending(path: "watches.json")
    try FileManager.default.createDirectory(at: file, withIntermediateDirectories: true)
    return WatchStore(fileURL: file)
  }

  /// Private, initially empty video-record store.
  private func temporaryRecordStore() -> VideoRecordStore {
    VideoRecordStore(fileURL: URL.temporaryDirectory
      .appending(path: "watching-records-\(UUID().uuidString)")
      .appending(path: "videos.json"))
  }

  /// Seed the record, then make its directory read-only (0500). Reads still succeed while save
  /// fails creating its scratch file, isolating the save-failure branch.
  private func writeProtectedRecordStore(seeding library: VideoLibrary) throws
    -> VideoRecordStore
  {
    let dir = URL.temporaryDirectory.appending(path: "watching-records-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let store = VideoRecordStore(fileURL: dir.appending(path: "videos.json"))
    // Seeded while the directory is still writable — `store.save` from
    // `stopWatching` is the one write this fixture exists to break.
    try store.save(library)
    try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: dir.path)
    return store
  }

  private func archive(_ id: String) -> ChannelArchive {
    ChannelArchive(id: id, title: "Stream \(id)", duration: .seconds(3600),
                   publishedAt: Date(timeIntervalSince1970: 0), status: .recorded,
                   thumbnailURL: nil)
  }

  /// Default to absent files. A blanket present stub would also match derived paths and report
  /// every archive downloaded.
  private func model(
    store: WatchStore,
    fileAnswer: @escaping (URL) -> ArchiveRowState.FileAnswer = { _ in .absent }
  ) -> WatchingModel {
    WatchingModel(
      store: store, videoRecordStore: temporaryRecordStore(),
      openIntake: { _, _ in },
      fileAnswer: fileAnswer)
  }

  /// Match only the delivered path, not the derived candidate.
  private let onlyTheJobsFile: (URL) -> ArchiveRowState.FileAnswer = { url in
    url.path(percentEncoded: false) == "/out/1.mp4" ? .present(url) : .absent
  }

  /// Single-step job associated with the archive ID. Done jobs carry a delivered artifact;
  /// callers can override the default path to match a precise filesystem stub.
  private func job(_ id: String, _ status: JobStatus, files: [URL] = []) -> Job {
    let stepStatus: StepStatus
    switch status {
    case .queued: stepStatus = .queued
    case .running: stepStatus = .running
    case .done: stepStatus = .done
    case .failed: stepStatus = .failed(StepFailure(kind: .noArtifact, summary: "no artifact"))
    case .cancelled: stepStatus = .cancelled
    }
    let artifact: URL? = status == .done ? (files.first ?? URL(filePath: "/out/\(id).mp4")) : nil
    let step = Step(
      id: StepID(rawValue: UUID()),
      kind: .downloadVideo(VideoRequest(
        videoID: id, quality: "", destination: URL(filePath: "/out/\(id).mp4"))),
      status: stepStatus,
      artifact: artifact)
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

  /// Progress-only snapshots must not rebuild and clear an action's failure banner.
  @Test func aProgressTickAloneDoesNotRebuild() async throws {
    let store = temporaryStore()
    try store.save([watch("ninja")])
    let model = WatchingModel(
      store: store, videoRecordStore: temporaryRecordStore(),
      openIntake: { _, _ in },
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
    let model = model(store: store, fileAnswer: onlyTheJobsFile)
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
    // Ignore hides immediately; persisted seen state must keep it hidden after reconciliation.
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

  /// Read seen IDs written through other store instances, not just local dismissals.
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
    // Inspect watches immediately after Ignore to catch rebuilding before persistence.
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
      store: store, videoRecordStore: temporaryRecordStore(),
      openIntake: { archive, _ in opened.id = archive.id },
      queue: { archive, watch in
        queued.id = archive.id
        queued.settings = watch.settings
        return nil
      })
    model.apply([.init(login: "ninja", displayName: "Ninja", outcome: .found([archive("1")]))])

    await model.add(archive("1"), from: "ninja")

    // Queue using frozen watch settings without reopening intake.
    #expect(queued.id == "1")
    #expect(queued.settings == capped.settings)
    #expect(opened.id == nil, "the primary action must not open intake")
    #expect(try store.load()[0].seen == ["1"])
    // This queue stub publishes no job, so the now-seen row hides. The next test supplies the
    // real queued-row transition.
    #expect(model.sections[0].rows.map(\.archive).isEmpty)
  }

  /// Publish during submission, as the engine does, so marking seen retains the row as queued.
  @Test func addingLeavesTheRowInPlaceAsQueuedOnceItsJobExists() async throws {
    let store = temporaryStore()
    try store.save([watch("ninja")])
    let held = ModelBox()
    let queued = job("1", .queued)
    let model = WatchingModel(
      store: store, videoRecordStore: temporaryRecordStore(),
      openIntake: { _, _ in },
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

  /// A queued job outranks persisted seen state even when another writer submitted it.
  @Test func anArchiveSeenOnDiskIsStillShownWhileTheQueueHoldsAJobForIt() throws {
    let store = temporaryStore()
    try store.save([watch("ninja", seen: ["1", "2"])])
    let model = model(store: store, fileAnswer: onlyTheJobsFile)
    model.apply([.init(login: "ninja", displayName: "Ninja",
                       outcome: .found([archive("1"), archive("2")]))])

    model.updateJobs([job("1", .done)])

    let rows = try #require(model.sections.first?.rows)
    #expect(rows.map(\.archive.id) == ["1"], "id 2 is seen with no job, so it stays hidden")
    #expect(rows.first?.state == .downloaded(URL(filePath: "/out/1.mp4")))
  }

  /// Removing a queue job must not clear handled state and authorize another automatic
  /// download.
  @Test func removingAJobHidesTheRowWithoutUnmarkingTheArchive() throws {
    let store = temporaryStore()
    try store.save([watch("ninja", seen: ["1"])])
    let model = model(store: store, fileAnswer: onlyTheJobsFile)
    model.apply([.init(login: "ninja", displayName: "Ninja", outcome: .found([archive("1")]))])
    model.updateJobs([job("1", .done)])
    #expect(model.sections[0].rows.count == 1)

    model.updateJobs([])

    #expect(model.sections[0].rows.isEmpty)
    #expect(try store.load()[0].seen == ["1"], "the seen-set never follows the queue")
  }

  /// Failed jobs must not keep ignored rows visible.
  @Test func ignoringARowWithAFailedJobRemovesItAndStillPersistsSeen() throws {
    let store = temporaryStore()
    try store.save([watch("ninja")])
    let model = model(store: store)
    model.apply([.init(login: "ninja", displayName: "Ninja", outcome: .found([archive("1")]))])
    model.updateJobs([job("1", .failed)])
    #expect(model.sections[0].rows.first?.state == .failed, "precondition: the row shows failed")

    model.ignore(archive("1"), from: "ninja")

    #expect(model.sections[0].rows.map(\.archive).isEmpty, "Ignore must actually remove the row")
    #expect(try store.load()[0].seen == ["1"], "the seen write still has to land")
  }

  /// Cancelled jobs must not resurrect ignored rows or unread counts.
  @Test func cancellingAJobForADismissedArchiveDoesNotBringItsRowBack() throws {
    let store = temporaryStore()
    try store.save([watch("ninja")])
    let model = model(store: store)
    model.apply([.init(login: "ninja", displayName: "Ninja", outcome: .found([archive("1")]))])
    model.ignore(archive("1"), from: "ninja")
    #expect(model.sections[0].rows.isEmpty, "precondition: Ignore hid the row")

    model.updateJobs([job("1", .cancelled)])

    #expect(model.sections[0].rows.map(\.archive).isEmpty, "a cancelled job must not resurrect it")
    #expect(model.unreadCount == 0)
  }

  /// Refused submission must leave the archive actionable.
  @Test func aRefusedAddSaysWhyAndLeavesTheRowAlone() async throws {
    let store = temporaryStore()
    try store.save([watch("ninja")])
    let model = WatchingModel(
      store: store, videoRecordStore: temporaryRecordStore(),
      openIntake: { _, _ in },
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
    let model = WatchingModel(
      store: store, videoRecordStore: temporaryRecordStore(),
      openIntake: { archive, _ in opened.id = archive.id })
    model.apply([.init(login: "ninja", displayName: "Ninja", outcome: .found([archive("1")]))])

    model.openInIntake(archive("1"), from: "ninja")

    #expect(opened.id == "1")
    // Seen on open, not on the eventual download: someone who opens the form
    // and cancels has still answered the question the row was asking.
    #expect(try store.load()[0].seen == ["1"])
    #expect(model.sections[0].rows.map(\.archive).isEmpty)
  }

  /// Verify frozen watch settings reach intake, rather than today's global defaults.
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
    let model = WatchingModel(
      store: store, videoRecordStore: temporaryRecordStore(),
      openIntake: { archive, watch in
        pending = PendingIntake(archiveID: archive.id, settings: watch.settings)
      })
    model.apply([.init(login: "ninja", displayName: "Ninja", outcome: .found([archive("1")]))])

    model.openInIntake(archive("1"), from: "ninja")

    let handedOff = try #require(pending)
    #expect(handedOff.archiveID == "1")
    #expect(handedOff.settings == capped.settings)
  }

  @Test func anActionOnAnUnknownChannelIsIgnoredRatherThanCrashing() throws {
    // The channel may have been removed since its findings arrived.
    let store = temporaryStore()
    try store.save([watch("ninja")])
    let model = model(store: store)
    model.apply([.init(login: "removed", displayName: "Removed",
                       outcome: .found([archive("1")]))])

    model.ignore(archive("1"), from: "removed")

    #expect(try store.load().map(\.login) == ["ninja"])
  }

  // MARK: - markSeen refuses loudly on an unreadable store

  /// Unreadable watch state must show a failure instead of silently hiding the row or skipping
  /// intake.
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
      store: store, videoRecordStore: temporaryRecordStore(),
      openIntake: { archive, _ in opened.id = archive.id },
      queue: { archive, _ in queued.id = archive.id; return nil })

    await model.add(archive("1"), from: "ninja")

    #expect(opened.id == nil, "no watch to hand to intake means no window should open")
    #expect(queued.id == nil, "a watch that cannot be read cannot compose a job")
    #expect(model.markSeenFailure != nil, "the refusal must say why, not just vanish")
  }

  /// Readable store with a nonwritable parent: save fails creating its scratch file, isolating
  /// the save branch from load errors.
  private func writeProtectedStore(seeding watches: [Watch]) throws -> WatchStore {
    let dir = URL.temporaryDirectory.appending(path: "watching-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let store = WatchStore(fileURL: dir.appending(path: "watches.json"))
    // Seed while the directory is still writable — `store.save` below is the
    // one write this test wants to survive.
    try store.save(watches)
    // 0500 allows reading/traversal but prevents creating the atomic-save scratch file.
    try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: dir.path)
    return store
  }

  /// Verify reads succeed before and after the action, while the seen ID remains absent, to
  /// prove the visible error came from save failure.
  @Test func ignoringOnAWriteProtectedStoreSurfacesTheSaveFailureRatherThanFailingSilently() throws {
    let store = try writeProtectedStore(seeding: [watch("ninja")])
    let dir = store.fileURL.deletingLastPathComponent()
    defer {
      // Restore the write bit before cleanup — `removeItem` on a read-only
      // directory would itself fail and leak the fixture.
      try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
      try? FileManager.default.removeItem(at: dir)
    }
    // Confirm this is a save failure, not a load failure.
    #expect(try store.load().map(\.login) == ["ninja"], "precondition: load must still succeed")

    let model = model(store: store)
    model.apply([.init(login: "ninja", displayName: "Ninja", outcome: .found([archive("1")]))])

    model.ignore(archive("1"), from: "ninja")

    #expect(model.markSeenFailure != nil, "a failed save must say why, not just vanish")
    #expect(
      try store.load()[0].seen.isEmpty,
      "the save must have actually failed — \"1\" never reached seen on disk")
  
    // Failed persistence restores the row immediately; the banner must describe that current
    // state.
    #expect(
      model.sections.first?.rows.map(\.id) == ["1"],
      "a failed save must leave the row where it was, not hide it")
    #expect(
      model.markSeenFailure?.contains("still here") == true,
      "the banner must describe what actually happened to the row")
  }

  @Test func aSweepThatStraddlesADismissalDoesNotBringTheRowBack() throws {
    // Reapply a sweep that still carries the ignored archive to model an in-flight stale
    // result.
    let store = temporaryStore()
    try store.save([watch("ninja")])
    let model = model(store: store)
    model.apply([.init(login: "ninja", displayName: "Ninja", outcome: .found([archive("1")]))])
    model.ignore(archive("1"), from: "ninja")

    model.apply([.init(login: "ninja", displayName: "Ninja", outcome: .found([archive("1")]))])

    #expect(model.sections[0].rows.map(\.archive).isEmpty)
  }

  @Test func aDismissalDropsOutOfTheOverlayButTheArchiveStaysHiddenViaTheWatchsOwnSeenSet() throws {
    // After an overlay ID is pruned, persisted seen state must still hide it if a later sweep
    // returns it again.
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

  /// A failed download unmarks through another store. Reconciliation must remove the stale
  /// local dismissal so the row returns in the same session.
  @Test func aFailedDownloadsArchiveReappearsInTheSameSessionOnceTheWatchForgetsIt() async throws {
    let store = temporaryStore()
    try store.save([watch("ninja")])
    let model = model(store: store)
    model.apply([.init(login: "ninja", displayName: "Ninja", outcome: .found([archive("1")]))])

    await model.add(archive("1"), from: "ninja")
    #expect(model.sections[0].rows.map(\.archive).isEmpty, "precondition: Add hid the row and marked it seen")

    // Simulate the failure observer unmarking archive 1 through another store.
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
    // Load watches before the first sweep so newly added channels appear immediately.
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
    // Hide chat size for video-only watch settings.
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
    // Remove the channel immediately despite retained sweep results.
    #expect(model.sections.map(\.login) == ["day9tv"])
    #expect(model.stopWatchingFailure == nil)
  }

  @Test func aSweepThatStraddlesAStopDoesNotResurrectTheStoppedChannel() throws {
    // Reapply a stale in-flight sweep after stopping; it must not resurrect the channel.
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
    // Re-add and refresh without another sweep, matching production. Old dismissals must not
    // hide IDs in the retained listing.
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

  // MARK: - Stopping a watch lets go of its records

  /// Stopping retains delivered records but removes unacted-on history.
  @Test func stoppingAChannelDropsRowsItHasNothingToShowForAndKeepsTheRest() throws {
    let store = temporaryStore()
    try store.save([watch("ninja"), watch("day9tv")])
    let records = temporaryRecordStore()
    var library = VideoLibrary()
    library.record(VideoRecord(id: "1", login: "ninja", deliveredPath: "/out/1.mp4"))
    library.record(VideoRecord(id: "2", login: "ninja"))
    library.record(VideoRecord(id: "3", login: "day9tv"))
    library.setState(.downloaded, for: "1")
    library.setState(.new, for: "2")
    library.setState(.new, for: "3")
    try records.save(library)
    let model = WatchingModel(
      store: store, videoRecordStore: records, openIntake: { _, _ in })

    model.stopWatching("ninja")

    let saved = try records.load()
    #expect(saved.videos["1"]?.deliveredPath == "/out/1.mp4",
            "a downloaded row is unrecoverable once dropped")
    #expect(saved.videos["2"] == nil)
    #expect(saved.videos["3"] != nil,
            "another channel's rows are none of this call's business")
    // The states go either way: `skipped`/`ignored` are statements about a
    // relationship with a channel, and there is no relationship left.
    #expect(saved.watchStates["1"] == nil)
    #expect(saved.watchStates["2"] == nil)
    #expect(saved.watchStates["3"] == .new)
  }

  /// Retain records for queued downloads before they have a delivered file.
  @Test func stoppingAChannelKeepsARowWhoseDownloadIsStillInTheQueue() throws {
    let store = temporaryStore()
    try store.save([watch("ninja")])
    let records = temporaryRecordStore()
    var library = VideoLibrary()
    library.record(VideoRecord(id: "2", login: "ninja"))
    try records.save(library)
    let model = WatchingModel(
      store: store, videoRecordStore: records, openIntake: { _, _ in })
    model.updateJobs([job("2", .running)])

    model.stopWatching("ninja")

    #expect(try records.load().videos["2"] != nil)
  }

  @Test func stoppingAChannelLetsGoOfImagesNothingReferencesAnyMore() throws {
    let kept = URL(string: "https://cdn/kept.jpg")!
    let dropped = URL(string: "https://cdn/dropped.jpg")!
    let store = temporaryStore()
    try store.save([watch("ninja")])
    let records = temporaryRecordStore()
    var library = VideoLibrary()
    library.record(VideoRecord(
      id: "1", login: "ninja", thumbnailURLs: [kept], deliveredPath: "/out/1.mp4"))
    library.record(VideoRecord(id: "2", login: "ninja", thumbnailURLs: [dropped]))
    try records.save(library)
    var purged: Set<URL>?
    let model = WatchingModel(
      store: store, videoRecordStore: records, openIntake: { _, _ in },
      purgeImages: { purged = $0 })

    model.stopWatching("ninja")

    // The keep-set, not the drop-set: the store is keyed by a one-way hash,
    // so what survives is named forward and everything else goes.
    #expect(purged == [kept])
  }

  /// Image keep-set must include other watches' avatars as well as video thumbnails. Assert the
  /// exact set so the stopped channel's unreferenced avatar remains purgeable.
  @Test func stoppingAChannelKeepsTheAvatarsOfChannelsStillBeingWatched() throws {
    let ninjaAvatar = URL(string: "https://cdn/ninja-avatar.png")!
    let day9Avatar = URL(string: "https://cdn/day9tv-avatar.png")!
    let thumbnail = URL(string: "https://cdn/kept.jpg")!
    let store = temporaryStore()
    try store.save([
      watch("ninja", avatarURL: ninjaAvatar),
      watch("day9tv", avatarURL: day9Avatar),
    ])
    let records = temporaryRecordStore()
    var library = VideoLibrary()
    library.record(VideoRecord(
      id: "3", login: "day9tv", thumbnailURLs: [thumbnail]))
    library.record(VideoRecord(
      id: "2", login: "ninja", thumbnailURLs: [URL(string: "https://cdn/dropped.jpg")!]))
    try records.save(library)
    var purged: Set<URL>?
    let model = WatchingModel(
      store: store, videoRecordStore: records, openIntake: { _, _ in },
      purgeImages: { purged = $0 })

    model.stopWatching("ninja")

    #expect(purged == [thumbnail, day9Avatar],
            "a still-watched channel's avatar is still referenced")
  }

  /// Delete payloads only for removed rows. Check a delivered row's payload survives to
  /// distinguish selective cleanup from deleting the whole channel.
  @Test func stoppingAChannelLetsGoOfTheDroppedRowsPayloads() throws {
    let store = temporaryStore()
    try store.save([watch("ninja")])
    let records = temporaryRecordStore()
    var library = VideoLibrary()
    library.record(VideoRecord(id: "1", login: "ninja", deliveredPath: "/out/1.mp4"))
    library.record(VideoRecord(id: "2", login: "ninja"))
    try records.save(library)

    let directory = URL.temporaryDirectory.appending(path: "payloads-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let payloads = PayloadStore(directory: directory)
    try payloads.save("kept", for: "1")
    try payloads.save("dropped", for: "2")

    let model = WatchingModel(
      store: store, videoRecordStore: records, openIntake: { _, _ in },
      payloads: payloads)

    model.stopWatching("ninja")

    #expect(try records.load().videos["2"] == nil, "precondition: the row was dropped")
    #expect(payloads.payload(for: "2") == nil)
    #expect(payloads.payload(for: "1") == "kept",
            "the row survived, so its payload is still reachable")
  }

  /// Purge payloads only after records save successfully; disk may still reference them if
  /// saving fails.
  @Test func aFailedRecordSaveLeavesThePayloadsAlone() throws {
    let store = temporaryStore()
    try store.save([watch("ninja")])
    var library = VideoLibrary()
    library.record(VideoRecord(id: "2", login: "ninja"))
    let records = try writeProtectedRecordStore(seeding: library)
    let dir = records.fileURL.deletingLastPathComponent()
    defer {
      try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
      try? FileManager.default.removeItem(at: dir)
    }

    let directory = URL.temporaryDirectory.appending(path: "payloads-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let payloads = PayloadStore(directory: directory)
    try payloads.save("still needed", for: "2")

    let model = WatchingModel(
      store: store, videoRecordStore: records, openIntake: { _, _ in },
      payloads: payloads)

    model.stopWatching("ninja")

    #expect(try records.load().videos["2"] != nil,
            "the save must have actually failed — the row is still on disk")
    #expect(payloads.payload(for: "2") == "still needed")
  }

  /// Break record save while keeping load functional. Purging against unsaved in-memory
  /// removals would delete images still referenced on disk, possibly their only surviving
  /// copies.
  @Test func aFailedRecordSaveLeavesTheImagesAlone() throws {
    let dropped = URL(string: "https://cdn/dropped.jpg")!
    let store = temporaryStore()
    try store.save([watch("ninja")])
    var library = VideoLibrary()
    library.record(VideoRecord(id: "2", login: "ninja", thumbnailURLs: [dropped]))
    let records = try writeProtectedRecordStore(seeding: library)
    let dir = records.fileURL.deletingLastPathComponent()
    defer {
      // Restore the write bit before cleanup — `removeItem` on a read-only
      // directory would itself fail and leak the fixture.
      try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
      try? FileManager.default.removeItem(at: dir)
    }
    #expect(try records.load().videos["2"] != nil, "precondition: the load must still succeed")

    var purged = false
    let model = WatchingModel(
      store: store, videoRecordStore: records, openIntake: { _, _ in },
      purgeImages: { _ in purged = true })

    model.stopWatching("ninja")

    #expect(try records.load().videos["2"] != nil,
            "the save must have actually failed — the row is still on disk")
    #expect(!purged, "a row still on disk still names its thumbnail")
    // The successful watch removal remains committed even if best-effort record cleanup fails.
    #expect(try store.load().isEmpty)
  }

  /// A stop that refused left the channel watched — so its rows are still a
  /// watched channel's rows, and its images are still referenced.
  @Test func aRefusedStopLeavesTheRecordAndTheImagesAlone() throws {
    let store = try unreadableStore()
    defer { try? FileManager.default.removeItem(at: store.fileURL.deletingLastPathComponent()) }
    let records = temporaryRecordStore()
    var library = VideoLibrary()
    library.record(VideoRecord(id: "2", login: "ninja"))
    try records.save(library)
    var purged = false
    let model = WatchingModel(
      store: store, videoRecordStore: records, openIntake: { _, _ in },
      purgeImages: { _ in purged = true })

    model.stopWatching("ninja")

    #expect(model.stopWatchingFailure != nil, "precondition: the stop refused")
    #expect(try records.load().videos["2"] != nil)
    #expect(!purged)
  }

  // MARK: - Re-reading the watch list on demand

  @Test func refreshShowsAChannelAddedToTheStoreAfterConstruction() throws {
    // Refresh must pick up channels added through another store without waiting for a sweep.
    let store = temporaryStore()
    try store.save([watch("ninja")])
    let model = model(store: store)
    #expect(model.sections.map(\.login) == ["ninja"])

    try store.save([watch("ninja"), watch("day9tv")])
    model.refresh()

    #expect(model.sections.map(\.login).sorted() == ["day9tv", "ninja"])
  }

  @Test func stopWatchingRefusesRatherThanOverwritingWhenTheStoreCannotBeRead() throws {
    // Unreadable state must not become an empty list that is then saved over existing watches.
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

  /// Clear stale stop failures on later rebuilds rather than indefinitely retaining them or
  /// tying them to another channel's successful stop.
  @Test func stopWatchingFailureIsClearedByAnyLaterActionNotJustAMatchingStop() throws {
    let file = URL.temporaryDirectory
      .appending(path: "watching-\(UUID().uuidString)")
      .appending(path: "watches.json")
    try FileManager.default.createDirectory(at: file, withIntermediateDirectories: true)
    let store = WatchStore(fileURL: file)
    let model = model(store: store)

    model.stopWatching("ninja")
    #expect(model.stopWatchingFailure != nil, "precondition: the refusal is visible")

    // Restore the store and refresh, as when returning to the pane.
    try FileManager.default.removeItem(at: file)
    try store.save([watch("day9tv")])
    model.refresh()

    #expect(
      model.stopWatchingFailure == nil,
      "a later, unrelated action must not leave a stale refusal on screen indefinitely")
  }

  // MARK: - The class invariant, under random interleaving

  /// Deterministically interleave sweeps, actions, refreshes, and external additions. After
  /// each operation, sections must match watched logins and archives must match the latest
  /// listing minus current handled state. All writes succeed here; failure paths have separate
  /// tests.
  @Test func watchesIsAlwaysTheSpineUnderRandomInterleaving() async throws {
    let seed: UInt64 = 0x5EED_C0FFEE
    var rng = SeededGenerator(seed: seed)

    let store = temporaryStore()
    let loginPool = ["ninja", "day9tv", "asmongold"]
    // Use platform-unique archive IDs across logins; collisions would create impossible
    // cross-channel dismissals.
    func ids(for login: String) -> [String] { (1...4).map { "\(login)-\($0)" } }

    try store.save([watch("ninja"), watch("day9tv")])
    let model = model(store: store)

    // Track the last raw listing per login. Retain it across stop/re-add, matching the model's
    // stale-listing behavior.
    var lastFound: [String: [ChannelArchive]] = [:]
    var lastFailed: Set<String> = []

    func currentLogins() throws -> [String] { try store.load().map(\.login) }

    func performSweep() throws {
      // Apply one complete sweep array, not one call per login, so overlay intersection sees
      // every channel. Keep raw archives and subtract current seen state during invariant
      // checks.
      var results: [WatchPollResult] = []
      for watchEntry in try store.load() {
        if Bool.random(using: &rng) {
          let raw = ids(for: watchEntry.login).filter { _ in Bool.random(using: &rng) }.map(archive)
          results.append(.init(login: watchEntry.login, displayName: watchEntry.displayName,
                               outcome: .found(raw)))
          lastFound[watchEntry.login] = raw
          lastFailed.remove(watchEntry.login)
        } else {
          results.append(.init(login: watchEntry.login, displayName: watchEntry.displayName,
                               outcome: .failed(.noSuchChannel)))
          lastFailed.insert(watchEntry.login)
        }
      }
      // Replace the expected listing wholesale, matching `apply`; a real sweep drops entries
      // for unwatched channels.
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
      // External writes add watches, matching Add Channel. Removals go through `stopWatching`,
      // which also cleans dismissals.
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
      // Refresh after the external add, matching window-close wiring.
      if step.isMultiple(of: 7) { model.refresh() }
      try checkInvariants(step: step)
    }
  }

  /// Stop then re-add and refresh without a new sweep. Retained listings must reappear
  /// immediately instead of looking like a never-polled empty channel.
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

  // MARK: - Regression: a downloaded archive must render, not disappear

  /// Checks model reconstruction from supplied results. The next real-sweep test covers
  /// filtering before results reach the model.
  @Test func aDownloadedArchiveRendersAsDownloaded() throws {
    let store = temporaryStore()
    try store.save([watch("ninja", seen: ["1"])])
    let file = URL(filePath: "/tmp/ninja-1.mp4")
    let model = WatchingModel(
      store: store, videoRecordStore: temporaryRecordStore(),
      openIntake: { _, _ in },
      fileAnswer: { _ in .present(file) })

    // The sweep now carries the seen archive through, which is the change.
    model.apply([.init(login: "ninja", displayName: "Ninja",
                       outcome: .found([archive("1")]))])
    model.updateJobs([job("1", .done, files: [file])])

    let rows = try #require(model.sections.first?.rows)
    #expect(rows.count == 1)
    #expect(rows.first?.state == .downloaded(file))
    #expect(model.unreadCount == 0, "a downloaded row is not waiting on anybody")
  }

  /// Call the real sweep with already-seen IDs, then apply its output. Hand-built results would
  /// miss the regression where sweep discarded downloaded history.
  @Test func aSeenAndDownloadedArchiveSurvivesARealSweep() async throws {
    let store = temporaryStore()
    try store.save([watch("ninja", seen: ["1"])])
    let file = URL(filePath: "/tmp/ninja-1.mp4")
    let model = WatchingModel(
      store: store, videoRecordStore: temporaryRecordStore(),
      openIntake: { _, _ in },
      fileAnswer: { _ in .present(file) })

    let seenArchive = archive("1")
    let results = await WatchPoll.sweep([watch("ninja", seen: ["1"])]) { _ in
      .success([seenArchive])
    }
    model.apply(results)
    model.updateJobs([job("1", .done, files: [file])])

    let rows = try #require(model.sections.first?.rows)
    #expect(rows.count == 1)
    #expect(rows.first?.state == .downloaded(file))
  }

  /// Channel-level volume status must report disconnection even when derived-path rows have no
  /// retained file claim.
  @Test func anUnreachableDestinationIsNamedOnTheChannel() throws {
    let store = temporaryStore()
    try store.save([watch("ninja")])
    let model = model(store: store, fileAnswer: { _ in .unknown(volumeName: "Storage") })
    model.apply([.init(login: "ninja", displayName: "Ninja", outcome: .found([archive("1")]))])

    #expect(model.sections[0].disconnectedDestination == "Storage")
  }

  /// The ordinary case must stay silent — a reachable destination naming a
  /// volume would put a false alarm on every channel.
  @Test func aReachableDestinationNamesNothing() throws {
    let store = temporaryStore()
    try store.save([watch("ninja")])
    let model = model(store: store, fileAnswer: { _ in .absent })
    model.apply([.init(login: "ninja", displayName: "Ninja", outcome: .found([archive("1")]))])

    #expect(model.sections[0].disconnectedDestination == nil)
  }


  /// Ignoring records why the row went away, so the display side stops having
  /// to infer it from the legacy seen-set.
  @Test func ignoringRecordsTheState() throws {
    let store = temporaryStore()
    try store.save([watch("ninja")])
    let records = temporaryRecordStore()
    defer { try? FileManager.default.removeItem(at: records.fileURL.deletingLastPathComponent()) }
    let model = WatchingModel(
      store: store, videoRecordStore: records, openIntake: { _, _ in },
      fileAnswer: { _ in .absent })
    model.apply([.init(login: "ninja", displayName: "Ninja", outcome: .found([archive("1")]))])

    model.ignore(archive("1"), from: "ninja")

    let library = try records.load()
    #expect(library.watchStates["1"] == .ignored)
    #expect(library.videos["1"]?.login == "ninja",
            "the row is recorded with the state, or removeWatch can never scope it away")
  }

  /// Record state only after the watch save succeeds; refused actions must not hide rows.
  @Test func aRefusedIgnoreRecordsNothing() throws {
    let store = try writeProtectedStore(seeding: [watch("ninja")])
    let dir = store.fileURL.deletingLastPathComponent()
    defer {
      try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
      try? FileManager.default.removeItem(at: dir)
    }
    let records = temporaryRecordStore()
    defer { try? FileManager.default.removeItem(at: records.fileURL.deletingLastPathComponent()) }
    let model = WatchingModel(
      store: store, videoRecordStore: records, openIntake: { _, _ in },
      fileAnswer: { _ in .absent })
    model.apply([.init(login: "ninja", displayName: "Ninja", outcome: .found([archive("1")]))])

    model.ignore(archive("1"), from: "ninja")

    #expect(model.markSeenFailure != nil, "precondition: the save must have failed")
    #expect(try records.load().watchStates["1"] == nil,
            "nothing may be recorded for an action that was refused")
  }


  /// Expired archives without files stay in history but leave the inbox.
  @Test func anExpiredArchiveIsHeldBackFromTheInboxButKeptInTheRecord() throws {
    let store = temporaryStore()
    try store.save([watch("ninja")])
    let records = temporaryRecordStore()
    defer { try? FileManager.default.removeItem(at: records.fileURL.deletingLastPathComponent()) }
    var library = VideoLibrary()
    library.record(VideoRecord(id: "gone", login: "ninja", title: "an old stream",
                               publishedAt: Date(timeIntervalSince1970: 0)))
    try records.save(library)

    let model = WatchingModel(
      store: store, videoRecordStore: records, openIntake: { _, _ in },
      fileAnswer: { _ in .absent })
    // The sweep lists something else entirely, so "gone" is not live.
    model.apply([.init(login: "ninja", displayName: "Ninja", outcome: .found([archive("1")]))])

    #expect(model.sections[0].rows.map(\.id) == ["1"], "the headstone stays out of the inbox")
    #expect(model.sections[0].allRows.map(\.id).sorted() == ["1", "gone"],
            "but the channel's own record keeps it")
  }

  /// Expired history must never be offered as an available download.
  @Test func theRecordCarriesTheHeadstoneMarkedExpired() throws {
    let store = temporaryStore()
    try store.save([watch("ninja")])
    let records = temporaryRecordStore()
    defer { try? FileManager.default.removeItem(at: records.fileURL.deletingLastPathComponent()) }
    var library = VideoLibrary()
    library.record(VideoRecord(id: "gone", login: "ninja", title: "an old stream",
                               publishedAt: Date(timeIntervalSince1970: 0)))
    try records.save(library)

    let model = WatchingModel(
      store: store, videoRecordStore: records, openIntake: { _, _ in },
      fileAnswer: { _ in .absent })
    model.apply([.init(login: "ninja", displayName: "Ninja", outcome: .found([archive("1")]))])

    #expect(model.sections[0].allRows.map(\.id).sorted() == ["1", "gone"])
    let headstone = try #require(model.sections[0].allRows.first { $0.id == "gone" })
    #expect(headstone.state == .expired, "never .available — Twitch cannot serve it")
    #expect(!headstone.state.isFetchable, "so the row must offer no Add")

    #expect(model.sections[0].rows.map(\.id) == ["1"], "and the inbox still holds it back")
  }

  // MARK: - The unfiltered record a channel's own destination shows

  /// Assert inbox rows are exactly the destination subset admitted by
  /// `belongsInTheDefaultView`, including future states.
  @Test func theInboxRowsAreASubsetOfAllRows() throws {
    let store = temporaryStore()
    try store.save([watch("ninja", seen: ["already-seen"])])
    let records = temporaryRecordStore()
    defer { try? FileManager.default.removeItem(at: records.fileURL.deletingLastPathComponent()) }
    var library = VideoLibrary()
    library.record(VideoRecord(id: "gone", login: "ninja", title: "an old stream",
                               publishedAt: Date(timeIntervalSince1970: 0)))
    try records.save(library)

    let model = WatchingModel(
      store: store, videoRecordStore: records, openIntake: { _, _ in },
      fileAnswer: { _ in .absent })
    // One genuinely new archive, and one the watch has already seen. Plus the
    // headstone from the record above, which the sweep no longer lists.
    model.apply([.init(login: "ninja", displayName: "Ninja",
                       outcome: .found([archive("1"), archive("already-seen")]))])

    let section = try #require(model.sections.first)
    let shown = Set(section.rows.map(\.id))
    let all = Set(section.allRows.map(\.id))

    #expect(shown == ["1"], "only the unseen, still-listed archive is inbox material")
    #expect(shown.isSubset(of: all))
    #expect(all.count > shown.count, "the fixture must actually hide something")
    #expect(all.subtracting(shown) == ["already-seen", "gone"],
            "and what it adds is exactly what belongsInTheDefaultView rejects")
  }

  /// Both lists share newest-first ordering.
  @Test func allRowsAreNewestFirst() throws {
    func dated(_ id: String, daysAgo: Int) -> ChannelArchive {
      ChannelArchive(
        id: id, title: "Stream \(id)", duration: .seconds(3600),
        publishedAt: Date(timeIntervalSince1970: 1_700_000_000
          - Double(daysAgo) * 86_400),
        status: .recorded, thumbnailURL: nil)
    }

    let store = temporaryStore()
    try store.save([watch("ninja", seen: ["middle"])])
    let records = temporaryRecordStore()
    defer { try? FileManager.default.removeItem(at: records.fileURL.deletingLastPathComponent()) }

    let model = WatchingModel(
      store: store, videoRecordStore: records, openIntake: { _, _ in },
      fileAnswer: { _ in .absent })
    // Supply unsorted rows with a hidden one in the middle to exercise both lists' sorting.
    model.apply([.init(login: "ninja", displayName: "Ninja", outcome: .found([
      dated("middle", daysAgo: 5),
      dated("oldest", daysAgo: 30),
      dated("newest", daysAgo: 1),
    ]))])

    let section = try #require(model.sections.first)
    #expect(section.allRows.map(\.id) == ["newest", "middle", "oldest"])
    let dates = section.allRows.map(\.archive.publishedAt)
    #expect(dates == dates.sorted(by: >))
  }

}

/// Seeded SplitMix64 makes failing interleavings reproducible.
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
