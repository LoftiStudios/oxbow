import Foundation
import Testing
@testable import OxbowKit

@Suite("WatchStore")
struct WatchStoreTests {

  private func temporaryFile() -> URL {
    URL.temporaryDirectory
      .appending(path: "watchstore-\(UUID().uuidString)")
      .appending(path: "watches.json")
  }

  private var sample: Watch {
    Watch(
      login: "ninja", displayName: "Ninja",
      settings: .init(destinationPath: "/Users/x/Downloads", qualityCap: .p720,
                      output: .video, chatSize: .large),
      downloadsAutomatically: true, seen: ["1", "2"])
  }

  @Test("an absent file loads as no watches rather than throwing")
  func absentFileIsEmpty() throws {
    let file = temporaryFile()
    defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
    #expect(try WatchStore(fileURL: file).load().isEmpty)
  }

  @Test("watches round-trip, frozen settings and seen-set included")
  func roundTrip() throws {
    let file = temporaryFile()
    defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
    let store = WatchStore(fileURL: file)
    try store.save([sample])
    let loaded = try store.load()

    #expect(loaded == [sample])
    #expect(loaded[0].settings.qualityCap == .p720)
    #expect(loaded[0].seen == ["1", "2"])
    #expect(loaded[0].downloadsAutomatically)
  }

  @Test("an unreadable file is moved aside rather than failing every launch")
  func corruptFileIsSetAside() throws {
    let file = temporaryFile()
    defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
    try FileManager.default.createDirectory(
      at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("{ not json".utf8).write(to: file)

    let store = WatchStore(fileURL: file)
    #expect(try store.load().isEmpty)
    #expect(FileManager.default.fileExists(atPath: file.appendingPathExtension("bak").path))
    #expect(!FileManager.default.fileExists(atPath: file.path))
  }

  /// The case the version field exists for, and the one the gate could not
  /// see: a future schema that changes `Watch`'s shape. `watches` must be
  /// non-empty with an element incompatible with the current `Watch` shape —
  /// an empty array decodes as a full `Envelope` regardless of version, so it
  /// cannot tell a version-first gate apart from one that decodes the whole
  /// envelope and checks the version afterward. Only a genuinely undecodable
  /// element proves the probe ran before the full decode did.
  @Test("a future schema version is set aside, not decoded")
  func setsAsideAFutureVersionWithAnIncompatibleWatchShape() throws {
    let file = temporaryFile()
    defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
    try FileManager.default.createDirectory(
      at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(#"{"version":99,"watches":[{"login":"ninja"}]}"#.utf8).write(to: file)

    #expect(try WatchStore(fileURL: file).load().isEmpty)
    #expect(FileManager.default.fileExists(atPath: file.appendingPathExtension("bak").path))
  }

  @Test("saving twice leaves no scratch files behind")
  func noScratchLeftBehind() throws {
    let file = temporaryFile()
    defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
    let store = WatchStore(fileURL: file)
    try store.save([sample])
    try store.save([])

    let siblings = try FileManager.default.contentsOfDirectory(
      atPath: file.deletingLastPathComponent().path)
    #expect(siblings == ["watches.json"])
  }
}
