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
}
