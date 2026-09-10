import Foundation
import Testing
@testable import OxbowKit

@Suite("VideoRecordStore")
struct VideoRecordStoreTests {

  private func temporaryFile() -> URL {
    URL.temporaryDirectory
      .appending(path: "videorecordstore-\(UUID().uuidString)")
      .appending(path: "videos.json")
  }

  private var sample: VideoLibrary {
    var library = VideoLibrary()
    library.record(VideoRecord(
      id: "2844787557", login: "wheelyf", title: "day 46",
      durationSeconds: 10203,
      publishedAt: Date(timeIntervalSince1970: 1_757_000_000),
      qualities: [StreamQuality(name: "1080p60", resolution: "1920x1080", bitsPerSecond: 6_000_000)],
      categoryName: "ELDEN RING",
      thumbnailURLs: [URL(string: "https://cdn/a.jpg")!],
      deliveredPath: "/Users/x/Downloads/day46.mp4",
      lastSeenOnTwitch: Date(timeIntervalSince1970: 1_757_100_000),
      payloadHelperVersion: "1.56.5"))
    library.setState(.downloaded, for: "2844787557")
    return library
  }

  @Test("an absent file loads as an empty library rather than throwing")
  func absentFileIsEmpty() throws {
    let file = temporaryFile()
    defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
    #expect(try VideoRecordStore(fileURL: file).load() == VideoLibrary())
  }

  @Test("a library round-trips with every field intact")
  func roundTrip() throws {
    let file = temporaryFile()
    defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
    let store = VideoRecordStore(fileURL: file)
    try store.save(sample)

    let loaded = try store.load()
    #expect(loaded == sample)
    #expect(loaded.videos["2844787557"]?.qualities.first?.name == "1080p60")
    #expect(loaded.videos["2844787557"]?.durationSeconds == 10203)
    #expect(loaded.watchStates["2844787557"] == .downloaded)
  }

  @Test("an unreadable file is moved aside rather than failing every launch")
  func corruptFileIsSetAside() throws {
    let file = temporaryFile()
    defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
    try FileManager.default.createDirectory(
      at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("{ not json".utf8).write(to: file)

    #expect(try VideoRecordStore(fileURL: file).load() == VideoLibrary())
    #expect(FileManager.default.fileExists(atPath: file.appendingPathExtension("bak").path))
  }

  /// A file from a future version must read as "wrong version" rather than as
  /// whatever a decode failure happens to look like.
  @Test("a future version is set aside rather than decoded")
  func futureVersionIsSetAside() throws {
    let file = temporaryFile()
    defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
    try FileManager.default.createDirectory(
      at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(#"{"version":99,"library":{"videos":{},"watchStates":{}}}"#.utf8).write(to: file)

    #expect(try VideoRecordStore(fileURL: file).load() == VideoLibrary())
  }

  @Test("saving twice leaves no scratch files behind")
  func noScratchLeak() throws {
    let file = temporaryFile()
    defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
    let store = VideoRecordStore(fileURL: file)
    try store.save(sample)
    try store.save(sample)

    let siblings = try FileManager.default.contentsOfDirectory(
      atPath: file.deletingLastPathComponent().path)
    #expect(siblings == ["videos.json"])
  }
}
