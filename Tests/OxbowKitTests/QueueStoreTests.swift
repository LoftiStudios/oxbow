import Foundation
import Testing
@testable import OxbowKit

@Suite("QueueStore")
struct QueueStoreTests {

  private func temporaryFile() -> URL {
    URL(filePath: NSTemporaryDirectory())
      .appending(path: "oxbow-queue-\(UUID().uuidString).json")
  }

  @Test func roundTripsJobs() throws {
    let url = temporaryFile()
    defer { try? FileManager.default.removeItem(at: url) }
    let store = QueueStore(fileURL: url)
    let jobs = [Build.job(1, Build.network(1, .done), Build.compute(2, .queued))]

    try store.save(jobs)
    #expect(try store.load() == jobs)
  }

  @Test func loadsEmptyWhenNoFileExists() throws {
    #expect(try QueueStore(fileURL: temporaryFile()).load().isEmpty)
  }

  /// An unrecognised schema must not crash or guess; it is set aside.
  @Test func setsAsideAnUnknownSchemaVersion() throws {
    let url = temporaryFile()
    let backup = url.appendingPathExtension("bak")
    defer {
      try? FileManager.default.removeItem(at: url)
      try? FileManager.default.removeItem(at: backup)
    }
    try #"{"version": 9999, "jobs": []}"#.write(to: url, atomically: true, encoding: .utf8)

    let store = QueueStore(fileURL: url)
    #expect(try store.load().isEmpty)
    #expect(FileManager.default.fileExists(atPath: backup.path))
  }

  /// A corrupt file must never be able to block launch. Without recovery here
  /// `load()` throws, `QueueEngine.start()` rethrows, the app cannot start,
  /// the bad file is never set aside, and it fails identically forever.
  @Test func setsAsideACorruptFile() throws {
    let url = temporaryFile()
    let backup = url.appendingPathExtension("bak")
    defer {
      try? FileManager.default.removeItem(at: url)
      try? FileManager.default.removeItem(at: backup)
    }
    try #"{"version": 1, "jobs": [{"#.write(to: url, atomically: true, encoding: .utf8)

    let store = QueueStore(fileURL: url)
    #expect(try store.load().isEmpty)
    #expect(FileManager.default.fileExists(atPath: backup.path))
  }

  /// The case the version field exists for, and the one the gate could not
  /// see: a future schema that changes `Job`'s shape. Decoding the payload
  /// before reading the version threw inside `[Job]` and never reached the
  /// check.
  @Test func setsAsideAFutureVersionWithAnIncompatibleJobShape() throws {
    let url = temporaryFile()
    let backup = url.appendingPathExtension("bak")
    defer {
      try? FileManager.default.removeItem(at: url)
      try? FileManager.default.removeItem(at: backup)
    }
    try #"{"version": 2, "jobs": [{"identifier": "abc", "phases": []}]}"#
      .write(to: url, atomically: true, encoding: .utf8)

    let store = QueueStore(fileURL: url)
    #expect(try store.load().isEmpty)
    #expect(FileManager.default.fileExists(atPath: backup.path))
  }

  /// A partially written file must never replace a good one.
  @Test func writesAtomically() throws {
    let url = temporaryFile()
    defer { try? FileManager.default.removeItem(at: url) }
    let store = QueueStore(fileURL: url)
    try store.save([Build.job(1, Build.network(1))])
    try store.save([Build.job(2, Build.network(2)), Build.job(3, Build.network(3))])
    #expect(try store.load().count == 2)
  }
}
