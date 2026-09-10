import Foundation
import Testing
@testable import OxbowKit

@Suite("PayloadStore")
struct PayloadStoreTests {

  private func temporaryDirectory() -> URL {
    URL.temporaryDirectory.appending(path: "payloadstore-\(UUID().uuidString)")
  }

  @Test("a payload round-trips verbatim")
  func roundTrip() throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = PayloadStore(directory: directory)

    // Three parts on three lines, the shape the CLI actually emits.
    let payload = "{\"data\":{\"video\":{}}}\n{\"data\":{\"video\":{}}}\n#EXTM3U\n"
    try store.save(payload, for: "2844787557")

    #expect(store.payload(for: "2844787557") == payload)
  }

  @Test("an absent payload reads as nil rather than throwing")
  func absentIsNil() {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    #expect(PayloadStore(directory: directory).payload(for: "nope") == nil)
  }

  /// A clip slug is `[A-Za-z0-9_-]`, a VOD id is digits — but this writes a
  /// filename from caller-supplied text, so an id that could escape the
  /// directory must be refused rather than sanitised into something else's
  /// filename.
  @Test("an id that could escape the directory is refused")
  func traversalIsRefused() {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = PayloadStore(directory: directory)

    #expect(throws: PayloadStore.Failure.unusableIdentifier) {
      try store.save("x", for: "../escape")
    }
    #expect(throws: PayloadStore.Failure.unusableIdentifier) {
      try store.save("x", for: "a/b")
    }
    #expect(throws: PayloadStore.Failure.unusableIdentifier) {
      try store.save("x", for: "")
    }
    #expect(store.payload(for: "../escape") == nil)
  }

  @Test("removing drops only the ids named")
  func removeIsScoped() throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = PayloadStore(directory: directory)
    try store.save("one", for: "1")
    try store.save("two", for: "2")

    store.remove(ids: ["1"])

    #expect(store.payload(for: "1") == nil)
    #expect(store.payload(for: "2") == "two")
  }
}
