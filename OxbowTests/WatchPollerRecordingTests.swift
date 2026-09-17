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

  /// Record all returned archives, including already-seen ones, for retained history.
  @Test("a sweep records every archive it saw")
  func sweepRecordsEverything() throws {
    let file = temporaryFile()
    defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
    let store = VideoRecordStore(fileURL: file)

    WatchPoller.record(
      archives: [archive("1"), archive("2")],
      forLogin: "wheelyf", displayName: "WheelyF",
      seenAt: Date(timeIntervalSince1970: 1_757_100_000),
      into: store)

    let library = try store.load()
    #expect(library.videos.keys.sorted() == ["1", "2"])
    #expect(library.videos["1"]?.title == "day 1")
    #expect(library.videos["1"]?.login == "wheelyf")
    // Carry display name separately; it cannot be derived from login.
    #expect(library.videos["1"]?.displayName == "WheelyF")
    #expect(library.videos["1"]?.durationSeconds == 10203)
    #expect(library.videos["1"]?.categoryName == "ELDEN RING")
    #expect(library.videos["1"]?.lastSeenOnTwitch == Date(timeIntervalSince1970: 1_757_100_000))
  }

  /// Sweeps must preserve submission-only facts.
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
      archives: [archive("1")], forLogin: "wheelyf", displayName: "WheelyF",
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

    WatchPoller.record(archives: [], forLogin: "wheelyf", displayName: "WheelyF",
                       seenAt: .now, into: store)

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

  /// A failed sweep must leave the record unchanged. This verifies the outcome, not which guard
  /// prevents the write: both sweep's outcome check and record's empty-array guard produce it.
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

  /// Migration must run before legacy handled IDs can be offered again.
  @Test("migrating at launch turns a stored seen-set into skipped state")
  func migrationRunsAtLaunch() throws {
    let file = temporaryFile()
    defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
    let store = VideoRecordStore(fileURL: file)

    let watch = Watch(
      login: "wheelyf", displayName: "WheelyF",
      settings: .init(destinationPath: "/tmp", qualityCap: .p720,
                      output: .video, chatSize: .large),
      downloadsAutomatically: false, seen: ["1", "2"])

    WatchPoller.migrateSeenIfNeeded(watches: [watch], into: store)

    let library = try store.load()
    #expect(library.seenIDs(forLogin: "wheelyf") == ["1", "2"])
    #expect(library.watchStates["1"] == .skipped)
  }

  /// Launching twice must not demote real progress back to skipped.
  @Test("migrating twice leaves recorded progress alone")
  func migrationIsSafeToRepeat() throws {
    let file = temporaryFile()
    defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
    let store = VideoRecordStore(fileURL: file)

    let watch = Watch(
      login: "wheelyf", displayName: "WheelyF",
      settings: .init(destinationPath: "/tmp", qualityCap: .p720,
                      output: .video, chatSize: .large),
      downloadsAutomatically: false, seen: ["1"])

    WatchPoller.migrateSeenIfNeeded(watches: [watch], into: store)

    var library = try store.load()
    library.setState(.downloaded, for: "1")
    try store.save(library)

    WatchPoller.migrateSeenIfNeeded(watches: [watch], into: store)

    #expect(try store.load().watchStates["1"] == .downloaded)
  }
}
