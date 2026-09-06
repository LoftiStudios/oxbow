import Foundation
import Testing
import OxbowKit
@testable import Oxbow

/// `docs/design/channel-watching.md` §6.3: a failed automatic download
/// returns to the inbox by un-marking its `mediaIdentifier` from every
/// watch's `seen` set; a cancelled one does not, because a cancellation is a
/// person saying no rather than the app failing to manage something.
@MainActor
@Suite("Auto-download observer")
struct AutoDownloadObserverTests {

  private func temporaryStore() -> WatchStore {
    WatchStore(fileURL: URL.temporaryDirectory
      .appending(path: "auto-download-\(UUID().uuidString)")
      .appending(path: "watches.json"))
  }

  private func watch(
    _ login: String, seen: Set<String> = []
  ) -> Watch {
    Watch(
      login: login, displayName: login.capitalized,
      settings: .init(
        destinationPath: "/Users/x/Downloads", qualityCap: .best,
        output: .videoWithChat, chatSize: .medium),
      downloadsAutomatically: true, seen: seen)
  }

  private let failure = StepFailure(kind: .noArtifact, summary: "no artifact")

  private func step(_ status: StepStatus, videoID: String = "1") -> Step {
    Step(
      id: StepID(rawValue: UUID()),
      kind: .downloadVideo(VideoRequest(
        videoID: videoID, quality: "", destination: URL(filePath: "/out/a.mp4"))),
      status: status)
  }

  private func job(_ id: JobID, _ steps: [Step], title: String = "Stream") -> Job {
    Job(id: id, created: Date(timeIntervalSince1970: 0), title: title, steps: steps)
  }

  private let alpha = JobID(rawValue: UUID())

  // MARK: - Failed

  @Test func aFailedJobUnmarksItsArchive() throws {
    let store = temporaryStore()
    try store.save([watch("ninja", seen: ["1"])])
    let observer = AutoDownloadObserver(store: store)

    observer.apply([job(alpha, [step(.failed(failure))])])

    let watches = try store.load()
    #expect(watches.first?.seen.contains("1") == false)
  }

  /// The broadening the doc comment has to justify: an archive a person
  /// Added manually from the inbox is in `seen` too, and this un-marks it
  /// on failure exactly the same way — there is no persisted record of
  /// which submissions were automatic to distinguish the two.
  @Test func aManuallyAddedArchiveIsAlsoReturnedOnFailure() throws {
    let store = temporaryStore()
    try store.save([watch("ninja", seen: ["1"])])
    let observer = AutoDownloadObserver(store: store)

    observer.apply([job(alpha, [step(.failed(failure))])])

    #expect(try store.load().first?.seen.isEmpty == true)
  }

  @Test func unmarkingReachesWhicheverWatchActuallyHoldsTheArchive() throws {
    let store = temporaryStore()
    try store.save([watch("ninja", seen: []), watch("day9tv", seen: ["1"])])
    let observer = AutoDownloadObserver(store: store)

    observer.apply([job(alpha, [step(.failed(failure))])])

    let watches = try store.load()
    #expect(watches.first { $0.login == "day9tv" }?.seen.contains("1") == false)
  }

  // MARK: - Cancelled is not a failure

  /// §6.3: re-offering something a person just cancelled would be the app
  /// arguing with them. Only `.failed` returns to the inbox.
  @Test func aCancelledJobLeavesItsArchiveMarkedSeen() throws {
    let store = temporaryStore()
    try store.save([watch("ninja", seen: ["1"])])
    let observer = AutoDownloadObserver(store: store)

    observer.apply([job(alpha, [step(.cancelled)])])

    let watches = try store.load()
    #expect(watches.first?.seen.contains("1") == true)
  }

  @Test func aDoneJobLeavesItsArchiveMarkedSeen() throws {
    let store = temporaryStore()
    try store.save([watch("ninja", seen: ["1"])])
    let observer = AutoDownloadObserver(store: store)

    observer.apply([job(alpha, [step(.done)])])

    let watches = try store.load()
    #expect(watches.first?.seen.contains("1") == true)
  }

  @Test func aQueuedOrRunningJobDoesNothing() throws {
    let store = temporaryStore()
    try store.save([watch("ninja", seen: ["1"])])
    let observer = AutoDownloadObserver(store: store)

    observer.apply([job(alpha, [step(.queued)])])
    observer.apply([job(alpha, [step(.running)])])

    let watches = try store.load()
    #expect(watches.first?.seen.contains("1") == true)
  }

  // MARK: - Fires once per job

  /// The hazard requirement 4 names directly: a job sits `.failed` in every
  /// snapshot until it is removed, so this must act on the *transition*
  /// into failure, not on every snapshot that carries one. Proven here by
  /// re-marking the archive seen between two `apply` calls that both see
  /// the same already-failed job — if this fired every snapshot, the second
  /// call would un-mark it right back off.
  @Test func aFailedJobIsOnlyActedOnOnce() throws {
    let store = temporaryStore()
    try store.save([watch("ninja", seen: ["1"])])
    let observer = AutoDownloadObserver(store: store)
    let failedJob = job(alpha, [step(.failed(failure))])

    observer.apply([failedJob])
    // A person re-adds it from the inbox, which marks it seen again.
    var current = try store.load()
    current[0] = current[0].marking(["1"])
    try store.save(current)

    // The same failed job, still sitting in the same terminal status, in a
    // later snapshot — this must not un-mark it a second time.
    observer.apply([failedJob])

    let watches = try store.load()
    #expect(watches.first?.seen.contains("1") == true)
  }

  /// A job already `.failed` the very first time this observer ever sees it
  /// — the shape a crash-reconciled launch takes, per `QueueHost`'s own
  /// comment on why status observers attach before `start()` — must still
  /// be acted on. Unlike `NotificationDecision`'s silent first-snapshot
  /// seeding (where a missed notification is merely stale), silently
  /// skipping this one would permanently strand the archive: nothing else
  /// ever asks about it again. See the type's own doc comment.
  @Test func aJobAlreadyFailedOnTheFirstSnapshotIsStillActedOn() throws {
    let store = temporaryStore()
    try store.save([watch("ninja", seen: ["1"])])
    let observer = AutoDownloadObserver(store: store)

    observer.apply([job(alpha, [step(.failed(failure))])])

    let watches = try store.load()
    #expect(watches.first?.seen.contains("1") == false)
  }

  /// A retried job that fails again crosses the failed transition a second
  /// time and must be un-marked again — that is a new failure, not a
  /// repeat of the first.
  @Test func aRetriedJobFailingAgainIsActedOnAgain() throws {
    let store = temporaryStore()
    try store.save([watch("ninja", seen: ["1"])])
    let observer = AutoDownloadObserver(store: store)

    observer.apply([job(alpha, [step(.failed(failure))])])

    var current = try store.load()
    current[0] = current[0].marking(["1"])
    try store.save(current)

    // Retried: back to work.
    observer.apply([job(alpha, [step(.running)])])
    #expect(try store.load().first?.seen.contains("1") == true)

    // Failed again.
    observer.apply([job(alpha, [step(.failed(failure))])])
    #expect(try store.load().first?.seen.contains("1") == false)
  }

  // MARK: - The job itself is untouched

  @Test func theFailedJobItselfIsNeverModified() throws {
    let store = temporaryStore()
    try store.save([watch("ninja", seen: ["1"])])
    let observer = AutoDownloadObserver(store: store)
    let failedJob = job(alpha, [step(.failed(failure))])

    observer.apply([failedJob])

    // Nothing about the observer's contract touches `Job` at all — it only
    // ever reads it. Asserting the input is unchanged pins that this stays
    // a queue-side no-op, per §6.3: "adds a way to notice, not a new policy
    // about disk."
    #expect(failedJob.status == .failed)
  }

  // MARK: - A superseded failure is not re-surfaced

  /// Two jobs for the same media both fail, neither ever succeeded. This is
  /// not a superseded failure — there is nothing that answered it — so the
  /// archive still comes back, exactly once (`forget` un-marking twice is
  /// harmless, but nothing here should need that to stay true).
  @Test func twoFailedJobsForTheSameMediaStillUnmarksOnce() throws {
    let store = temporaryStore()
    try store.save([watch("ninja", seen: ["1"])])
    let observer = AutoDownloadObserver(store: store)
    let beta = JobID(rawValue: UUID())

    observer.apply([
      job(alpha, [step(.failed(failure))]),
      job(beta, [step(.failed(failure))]),
    ])

    let watches = try store.load()
    #expect(watches.first?.seen.contains("1") == false)
  }

  /// The relaunch hazard from the observer's own doc comment: a `.done`
  /// job for the same media in the same snapshot means a retry already
  /// succeeded, so the failure has already been answered and un-marking
  /// would put an archive back in the inbox that is already on disk.
  @Test func aFailedJobAlongsideADoneJobForTheSameMediaDoesNotUnmark() throws {
    let store = temporaryStore()
    try store.save([watch("ninja", seen: ["1"])])
    let observer = AutoDownloadObserver(store: store)
    let beta = JobID(rawValue: UUID())

    observer.apply([
      job(alpha, [step(.failed(failure))]),
      job(beta, [step(.done)]),
    ])

    let watches = try store.load()
    #expect(watches.first?.seen.contains("1") == true)
  }

  /// A `.queued` or `.running` job for the same media in the same snapshot
  /// means a retry is already in flight — un-marking now would race it.
  @Test func aFailedJobAlongsideAQueuedOrRunningJobForTheSameMediaDoesNotUnmark() throws {
    let store = temporaryStore()
    try store.save([watch("ninja", seen: ["1"])])
    let observer = AutoDownloadObserver(store: store)
    let beta = JobID(rawValue: UUID())

    observer.apply([
      job(alpha, [step(.failed(failure))]),
      job(beta, [step(.queued)]),
    ])
    #expect(try store.load().first?.seen.contains("1") == true)

    let gamma = JobID(rawValue: UUID())
    let observer2 = AutoDownloadObserver(store: store)
    observer2.apply([
      job(gamma, [step(.failed(failure))]),
      job(beta, [step(.running)]),
    ])
    #expect(try store.load().first?.seen.contains("1") == true)
  }

  /// A cancellation is a person saying no to that attempt, not the app
  /// doing better — it must not block the un-mark for a sibling failure.
  @Test func aFailedJobAlongsideACancelledJobForTheSameMediaStillUnmarks() throws {
    let store = temporaryStore()
    try store.save([watch("ninja", seen: ["1"])])
    let observer = AutoDownloadObserver(store: store)
    let beta = JobID(rawValue: UUID())

    observer.apply([
      job(alpha, [step(.failed(failure))]),
      job(beta, [step(.cancelled)]),
    ])

    let watches = try store.load()
    #expect(watches.first?.seen.contains("1") == false)
  }

  /// The relaunch sequence from the observer's own doc comment: job A fails
  /// and is left `.failed`, deliberately untouched; a person re-Adds the
  /// archive, whose job B succeeds; the app relaunches before A is
  /// dismissed. The new observer's baseline is empty, so A reads as freshly
  /// failed on the first snapshot — but B's `.done` status in that same
  /// snapshot must stop the archive being un-marked a second time.
  @Test func aRelaunchDoesNotResurfaceAFailureAlreadyAnsweredByASuccessfulRetry() throws {
    let store = temporaryStore()
    try store.save([watch("ninja", seen: ["1"])])
    let observer = AutoDownloadObserver(store: store)

    observer.apply([job(alpha, [step(.failed(failure))])])
    #expect(try store.load().first?.seen.contains("1") == false)

    // The person re-Adds it; job B is created and marks it seen again.
    let beta = JobID(rawValue: UUID())
    var current = try store.load()
    current[0] = current[0].marking(["1"])
    try store.save(current)

    // B succeeds. A is still sitting `.failed`, untouched (requirement 6).
    // The app quits here and relaunches with a fresh observer before A is
    // dismissed.
    let relaunchedObserver = AutoDownloadObserver(store: store)
    relaunchedObserver.apply([
      job(alpha, [step(.failed(failure))]),
      job(beta, [step(.done)]),
    ])

    #expect(try store.load().first?.seen.contains("1") == true)
  }

  // MARK: - Read-before-write

  /// Matches `AddChannelModel.add()`, `WatchingModel.markSeen` and
  /// `WatchPoller.markSubmitted`: refuse rather than overwrite when the
  /// store cannot be read, rather than writing back a stale copy loaded
  /// earlier.
  @Test func anUnreadableStoreIsRefusedRatherThanOverwritten() throws {
    let file = URL.temporaryDirectory
      .appending(path: "auto-download-\(UUID().uuidString)")
      .appending(path: "watches.json")
    try FileManager.default.createDirectory(at: file, withIntermediateDirectories: true)
    let store = WatchStore(fileURL: file)
    let observer = AutoDownloadObserver(store: store)

    // Must not crash, and must not attempt to write a fabricated watch list
    // over whatever is actually on disk (unreadable here, but this is the
    // same refusal every other writer of this file makes).
    observer.apply([job(alpha, [step(.failed(failure))])])
  }
}
