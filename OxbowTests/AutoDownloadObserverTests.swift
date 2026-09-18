import Foundation
import Testing
import OxbowKit
@testable import Oxbow

/// Failed downloads return to the inbox; cancellation records a deliberate decision and stays
/// handled.
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

  /// Manual inbox submissions also return on failure; submission origin is not persisted.
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

  /// Only failure returns an archive to the inbox; cancellation is deliberate.
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

  /// Re-mark between identical failed snapshots to prove only the transition triggers
  /// unmarking.
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

  /// Act on failures in the first snapshot too, including crash-reconciled jobs that would
  /// otherwise remain hidden.
  @Test func aJobAlreadyFailedOnTheFirstSnapshotIsStillActedOn() throws {
    let store = temporaryStore()
    try store.save([watch("ninja", seen: ["1"])])
    let observer = AutoDownloadObserver(store: store)

    observer.apply([job(alpha, [step(.failed(failure))])])

    let watches = try store.load()
    #expect(watches.first?.seen.contains("1") == false)
  }

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

    // The observer must not mutate queue jobs.
    #expect(failedJob.status == .failed)
  }

  // MARK: - A superseded failure is not re-surfaced

  /// Two unsuperseded failures for one video return it once.
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

  /// A completed retry in the same snapshot supersedes the older failure.
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

  /// After relaunch, a successful replacement job must prevent an older failed job from
  /// returning the archive to the inbox.
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

    // Relaunch with A still failed and B complete.
    let relaunchedObserver = AutoDownloadObserver(store: store)
    relaunchedObserver.apply([
      job(alpha, [step(.failed(failure))]),
      job(beta, [step(.done)]),
    ])

    #expect(try store.load().first?.seen.contains("1") == true)
  }

  // MARK: - Read-before-write

  /// Refuse unreadable state, as all other watch-list writers do.
  @Test func anUnreadableStoreIsRefusedRatherThanOverwritten() throws {
    let file = URL.temporaryDirectory
      .appending(path: "auto-download-\(UUID().uuidString)")
      .appending(path: "watches.json")
    try FileManager.default.createDirectory(at: file, withIntermediateDirectories: true)
    let store = WatchStore(fileURL: file)
    let observer = AutoDownloadObserver(store: store)

    observer.apply([job(alpha, [step(.failed(failure))])])
  }
}
