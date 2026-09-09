import Foundation
import Testing
import OxbowKit
@testable import Oxbow

@Suite("Watch poller recording")
@MainActor
struct WatchPollerRecordingTests {

  private func temporaryFile() -> URL {
    URL.temporaryDirectory
      .appending(path: "poller-record-\(UUID().uuidString)")
      .appending(path: "videos.json")
  }

  private func archive(_ id: String) -> ChannelArchive {
    ChannelArchive(
      id: id, title: "day \(id)", duration: .seconds(10203),
      publishedAt: Date(timeIntervalSince1970: 1_757_000_000),
      status: .recorded,
      thumbnailURL: URL(string: "https://cdn/\(id).jpg"),
      categoryName: "ELDEN RING",
      categoryArtURL: nil)
  }

  /// Every archive a sweep sees is recorded, not just the unseen ones — the
  /// record is what makes an expired video still render, and an archive
  /// already downloaded is exactly the one worth keeping.
  @Test("a sweep records every archive it saw")
  func sweepRecordsEverything() throws {
    let file = temporaryFile()
    defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
    let store = VideoRecordStore(fileURL: file)

    WatchPoller.record(
      archives: [archive("1"), archive("2")],
      forLogin: "wheelyf",
      seenAt: Date(timeIntervalSince1970: 1_757_100_000),
      into: store)

    let library = try store.load()
    #expect(library.videos.keys.sorted() == ["1", "2"])
    #expect(library.videos["1"]?.title == "day 1")
    #expect(library.videos["1"]?.login == "wheelyf")
    #expect(library.videos["1"]?.durationSeconds == 10203)
    #expect(library.videos["1"]?.categoryName == "ELDEN RING")
    #expect(library.videos["1"]?.lastSeenOnTwitch == Date(timeIntervalSince1970: 1_757_100_000))
  }

  /// The whole point of the merge rule: a sweep after a submission must not
  /// erase the qualities and payload stamp the submission recorded.
  @Test("a sweep does not erase what a submission recorded")
  func sweepPreservesSubmissionFacts() throws {
    let file = temporaryFile()
    defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
    let store = VideoRecordStore(fileURL: file)

    var seeded = VideoLibrary()
    seeded.record(VideoRecord(
      id: "1", login: "wheelyf",
      qualities: [StreamQuality(name: "1080p60", resolution: "1920x1080", bitsPerSecond: 6_000_000)],
      payloadHelperVersion: "1.56.5"))
    try store.save(seeded)

    WatchPoller.record(
      archives: [archive("1")], forLogin: "wheelyf",
      seenAt: Date(timeIntervalSince1970: 1_757_100_000), into: store)

    let library = try store.load()
    #expect(library.videos["1"]?.qualities.count == 1)
    #expect(library.videos["1"]?.payloadHelperVersion == "1.56.5")
    #expect(library.videos["1"]?.title == "day 1")
  }

  @Test("recording nothing writes nothing")
  func emptySweepIsNoOp() throws {
    let file = temporaryFile()
    defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
    let store = VideoRecordStore(fileURL: file)

    WatchPoller.record(archives: [], forLogin: "wheelyf", seenAt: .now, into: store)

    #expect(!FileManager.default.fileExists(atPath: file.path))
  }

  private func temporaryWatchStore(_ watches: [Watch]) throws -> WatchStore {
    let store = WatchStore(fileURL: URL.temporaryDirectory
      .appending(path: "poller-record-watches-\(UUID().uuidString)")
      .appending(path: "watches.json"))
    try store.save(watches)
    return store
  }

  private func watch(_ login: String) -> Watch {
    Watch(login: login, displayName: login.capitalized,
          settings: Watch.Settings(
            destinationPath: "/Users/x/Downloads", qualityCap: .p360,
            output: .video, chatSize: .medium),
          downloadsAutomatically: false, seen: [])
  }

  /// A feed that fails every login with a server error — enough to reach
  /// `sweep()`'s `.failed(...)` branch without needing a specific error case.
  private func failingFeed() -> ChannelFeed {
    ChannelFeed(fetch: { request in
      (Data(), HTTPURLResponse(
        url: request.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!)
    })
  }

  /// The gap the reviewer found by inspection only: nothing pinned that a
  /// **failed** sweep records nothing. This drives a real `WatchPoller
  /// .refreshNow()` rather than calling `record(archives:forLogin:seenAt:
  /// into:)` directly, because the guard being pinned lives one level up —
  /// `sweep()`'s explicit `case .found(let archives) = result.outcome`
  /// match. `WatchPollResult.archives` flattens a `.failed` outcome to `[]`,
  /// so a version of `sweep()` that read `result.archives` instead of
  /// matching on `result.outcome` would call `record(archives: [], ...)` for
  /// a failure exactly as it does for a genuinely empty success — passing
  /// `emptySweepIsNoOp()` above for the wrong reason. Seeding an existing
  /// record and asserting it is byte-for-byte unchanged (not merely that no
  /// *new* row appeared) is what catches that: `record` is a no-op on an
  /// empty archive list either way, but only the `.found` match guarantees
  /// `seenAt` is never considered at all when the sweep failed.
  @Test("a failed sweep records nothing and stamps no last-seen time")
  func failedSweepLeavesRecordUntouched() async throws {
    let file = temporaryFile()
    defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
    let store = VideoRecordStore(fileURL: file)

    let seenBefore = Date(timeIntervalSince1970: 1_700_000_000)
    var seeded = VideoLibrary()
    seeded.record(VideoRecord(id: "1", login: "wheelyf", lastSeenOnTwitch: seenBefore))
    try store.save(seeded)

    let poller = WatchPoller(
      store: try temporaryWatchStore([watch("wheelyf")]),
      feed: failingFeed(),
      videoRecordStore: store)

    await poller.refreshNow()

    guard case .failed = poller.results.first?.outcome else {
      Issue.record("expected a failed outcome, got \(String(describing: poller.results.first?.outcome))")
      return
    }

    let library = try store.load()
    #expect(library.videos.count == 1)
    #expect(library.videos["1"]?.lastSeenOnTwitch == seenBefore)
  }
}
