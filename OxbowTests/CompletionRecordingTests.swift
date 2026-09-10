import Foundation
import Testing
import OxbowKit
@testable import Oxbow

@Suite("Completion recording")
@MainActor
struct CompletionRecordingTests {

  private func temporaryFile() -> URL {
    URL.temporaryDirectory
      .appending(path: "completion-\(UUID().uuidString)")
      .appending(path: "videos.json")
  }

  @Test("a finished job records its delivered file and the downloaded state")
  func finishedRecordsPath() throws {
    let file = temporaryFile()
    defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
    let store = VideoRecordStore(fileURL: file)

    VideoRecorder.recordCompletion(
      mediaIdentifier: "2844787557", outcome: .finished,
      files: [URL(filePath: "/Volumes/Helios/day46.mp4")], into: store)

    let library = try store.load()
    #expect(library.videos["2844787557"]?.deliveredPath == "/Volumes/Helios/day46.mp4")
    #expect(library.watchStates["2844787557"] == .downloaded)
  }

  /// A composite job delivers several files. The video is what the row is
  /// about, so the first delivered file is the one recorded — and the rest are
  /// still reachable from the job itself.
  @Test("the first delivered file is the one recorded")
  func firstFileWins() throws {
    let file = temporaryFile()
    defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
    let store = VideoRecordStore(fileURL: file)

    VideoRecorder.recordCompletion(
      mediaIdentifier: "1", outcome: .finished,
      files: [URL(filePath: "/a/video.mp4"), URL(filePath: "/a/chat.json")], into: store)

    #expect(try store.load().videos["1"]?.deliveredPath == "/a/video.mp4")
  }

  /// `failed` counts as not-seen, so the archive becomes actionable again —
  /// `WatchState.countsAsSeen` is what makes that true, and this is the write
  /// that puts it in that state.
  @Test("a failed job records the failed state and no path")
  func failedRecordsNoPath() throws {
    let file = temporaryFile()
    defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
    let store = VideoRecordStore(fileURL: file)

    VideoRecorder.recordCompletion(
      mediaIdentifier: "1", outcome: .failed, files: [], into: store)

    let library = try store.load()
    #expect(library.watchStates["1"] == .failed)
    #expect(library.videos["1"]?.deliveredPath == nil)
    #expect(library.seenIDs(forLogin: "wheelyf").isEmpty)
  }

  /// A finished job with nothing delivered must not claim a file.
  @Test("a finished job with no files records no path")
  func finishedWithNoFiles() throws {
    let file = temporaryFile()
    defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
    let store = VideoRecordStore(fileURL: file)

    VideoRecorder.recordCompletion(
      mediaIdentifier: "1", outcome: .finished, files: [], into: store)

    #expect(try store.load().videos["1"]?.deliveredPath == nil)
    #expect(try store.load().watchStates["1"] == .downloaded)
  }

  /// Completion must not erase the title and qualities a submission recorded.
  @Test("completion preserves the facts already recorded")
  func completionPreservesFacts() throws {
    let file = temporaryFile()
    defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
    let store = VideoRecordStore(fileURL: file)

    var seeded = VideoLibrary()
    seeded.record(VideoRecord(id: "1", login: "wheelyf", title: "day 46"))
    try store.save(seeded)

    VideoRecorder.recordCompletion(
      mediaIdentifier: "1", outcome: .finished,
      files: [URL(filePath: "/a/v.mp4")], into: store)

    let library = try store.load()
    #expect(library.videos["1"]?.title == "day 46")
    #expect(library.videos["1"]?.login == "wheelyf")
  }
}
