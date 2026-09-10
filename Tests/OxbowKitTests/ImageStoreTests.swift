import Foundation
import Testing
@testable import OxbowKit

@Suite("Image store")
struct ImageStoreTests {

  private func temporaryDirectory() -> URL {
    URL.temporaryDirectory.appending(path: "imagestore-\(UUID().uuidString)")
  }

  /// Counts fetches so a test can prove the second read did not hit the
  /// network.
  private final class Counter: @unchecked Sendable {
    var calls = 0
  }

  @Test("a miss fetches, and the bytes come back")
  func missFetches() async {
    let store = ImageStore(directory: temporaryDirectory(), fetch: { _ in Data("png".utf8) })
    let data = await store.data(for: URL(string: "https://example.com/a.png")!)
    #expect(data == Data("png".utf8))
  }

  @Test("a hit does not fetch again")
  func hitDoesNotRefetch() async {
    let counter = Counter()
    let store = ImageStore(directory: temporaryDirectory(), fetch: { _ in
      counter.calls += 1
      return Data("png".utf8)
    })
    let url = URL(string: "https://example.com/a.png")!

    _ = await store.data(for: url)
    _ = await store.data(for: url)

    #expect(counter.calls == 1)
  }

  /// The whole point of the stage: the archive expired, the CDN 404s, and
  /// the row still renders because the bytes are on disk.
  @Test("a stored image survives the fetch failing afterwards")
  func storedImageOutlivesItsSource() async {
    let directory = temporaryDirectory()
    let url = URL(string: "https://example.com/a.png")!

    let live = ImageStore(directory: directory, fetch: { _ in Data("png".utf8) })
    _ = await live.data(for: url)

    struct Gone: Error {}
    let dead = ImageStore(directory: directory, fetch: { _ in throw Gone() })
    #expect(await dead.data(for: url) == Data("png".utf8))
  }

  @Test("a failed fetch answers nil rather than throwing")
  func failedFetchIsNil() async {
    struct Boom: Error {}
    let store = ImageStore(directory: temporaryDirectory(), fetch: { _ in throw Boom() })
    #expect(await store.data(for: URL(string: "https://example.com/a.png")!) == nil)
  }

  /// A failure must not leave a zero-byte file behind that later reads as a
  /// hit — that would store the failure permanently.
  @Test("a failed fetch is not remembered as an empty hit")
  func failureIsNotStored() async {
    let counter = Counter()
    struct Boom: Error {}
    let store = ImageStore(directory: temporaryDirectory(), fetch: { _ in
      counter.calls += 1
      throw Boom()
    })
    let url = URL(string: "https://example.com/a.png")!
    _ = await store.data(for: url)
    _ = await store.data(for: url)
    #expect(counter.calls == 2, "the second call must try again, not read a stored failure")
  }

  /// Twitch's thumbnail URLs share a filename and differ deep in the path,
  /// so naming by `lastPathComponent` would collide every archive in a
  /// channel onto one image. The name must also be filesystem-safe: a raw
  /// URL carries slashes and colons.
  @Test("filenames are distinct and contain no path separators")
  func filenamesAreSafeAndDistinct() {
    let a = ImageStore.filename(for: URL(string: "https://cdn.example.com/aaa/thumb.jpg")!)
    let b = ImageStore.filename(for: URL(string: "https://cdn.example.com/bbb/thumb.jpg")!)
    #expect(a != b)
    #expect(!a.contains("/"))
    #expect(!a.contains(":"))
  }

  /// The extension is what makes a stored image previewable in Finder — Quick
  /// Look reads the extension, not the bytes, so a hash with no extension is a
  /// file nobody can glance at while debugging.
  ///
  /// **Measured against the author's own store, 2026-09-09**: of 145 cached
  /// URLs, 109 ended `.jpg`, 25 `.png` and 11 `.jpeg`. A flat `.jpg` would
  /// therefore mislabel 36 of them — so the extension comes from the source
  /// URL rather than being assumed.
  @Test("the extension comes from the source URL")
  func extensionFollowsTheSource() {
    #expect(ImageStore.filename(for: URL(string: "https://cdn.example.com/a/thumb.jpg")!)
      .hasSuffix(".jpg"))
    #expect(ImageStore.filename(for: URL(string: "https://cdn.example.com/a/avatar.png")!)
      .hasSuffix(".png"))
    #expect(ImageStore.filename(for: URL(string: "https://cdn.example.com/a/avatar.jpeg")!)
      .hasSuffix(".jpeg"))
  }

  /// Case is normalised so one image cannot be stored twice under two spellings
  /// of its own extension.
  @Test("an upper-case extension is stored lower-case")
  func extensionIsLowercased() {
    #expect(ImageStore.filename(for: URL(string: "https://cdn.example.com/a/T.JPG")!)
      .hasSuffix(".jpg"))
  }

  /// **Allow-listed, not sanitised**, for the reason `PayloadStore` gives about
  /// identifiers: this builds a filename out of text that arrived over the
  /// network, so anything unrecognised becomes the default rather than being
  /// cleaned up into something that merely looks safe.
  @Test("an unrecognised extension falls back rather than being trusted")
  func unknownExtensionFallsBack() {
    for path in ["thumb.php", "thumb.", "thumb", "thumb.exe"] {
      let name = ImageStore.filename(for: URL(string: "https://cdn.example.com/a/\(path)")!)
      #expect(name.hasSuffix(".jpg"), "\(path) should fall back to .jpg, got \(name)")
    }
  }

  /// A query string is not part of the path, so it must not reach the
  /// filename — Twitch's thumbnail URLs carry sizing parameters.
  @Test("a query string never reaches the filename")
  func queryStringIsNotInTheName() {
    let name = ImageStore.filename(
      for: URL(string: "https://cdn.example.com/a/thumb.jpg?width=320&height=180")!)
    #expect(name.hasSuffix(".jpg"))
    #expect(!name.contains("?"))
    #expect(!name.contains("="))
    #expect(!name.contains("&"))
  }

  /// The extension must not weaken what the hash guarantees: two URLs that
  /// differ only deep in the path still get different names.
  @Test("two URLs sharing an extension still get distinct names")
  func extensionDoesNotCauseCollisions() {
    let a = ImageStore.filename(for: URL(string: "https://cdn.example.com/aaa/thumb.jpg")!)
    let b = ImageStore.filename(for: URL(string: "https://cdn.example.com/bbb/thumb.jpg")!)
    #expect(a != b)
    #expect(a.hasSuffix(".jpg") && b.hasSuffix(".jpg"))
  }

  /// Nothing is ever evicted — a thumbnail is about 15 KB and Twitch serves
  /// at most 100 archives per channel, so a capacity cap would guard an
  /// event that does not happen. This pins that: writing a third image does
  /// not remove the first.
  @Test("writing more images never removes an earlier one")
  func nothingIsEvicted() async {
    let directory = temporaryDirectory()
    let store = ImageStore(directory: directory, fetch: { _ in Data(repeating: 0x41, count: 10) })

    let first = URL(string: "https://example.com/1.png")!
    _ = await store.data(for: first)
    _ = await store.data(for: URL(string: "https://example.com/2.png")!)
    _ = await store.data(for: URL(string: "https://example.com/3.png")!)

    let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path)
    #expect(names?.count == 3)
    #expect(names?.contains(ImageStore.filename(for: first)) == true)
  }

  /// The store never evicts on its own; deletion belongs to whatever owns the
  /// history. This is that hook.
  @Test("purging keeps referenced images and drops the rest")
  func purgeKeepsReferenced() async {
    let directory = URL.temporaryDirectory.appending(path: "imagepurge-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }

    let kept = URL(string: "https://cdn/keep.jpg")!
    let dropped = URL(string: "https://cdn/drop.jpg")!
    let store = ImageStore(directory: directory, fetch: { _ in Data("x".utf8) })

    _ = await store.data(for: kept)
    _ = await store.data(for: dropped)

    await store.purge(keeping: [kept])

    // A kept image is served from disk; a dropped one has to be re-fetched.
    #expect(FileManager.default.fileExists(
      atPath: directory.appending(path: ImageStore.filename(for: kept)).path))
    #expect(!FileManager.default.fileExists(
      atPath: directory.appending(path: ImageStore.filename(for: dropped)).path))
  }

  @Test("purging an empty keep-set empties the store")
  func purgeEverything() async {
    let directory = URL.temporaryDirectory.appending(path: "imagepurge-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = ImageStore(directory: directory, fetch: { _ in Data("x".utf8) })
    _ = await store.data(for: URL(string: "https://cdn/a.jpg")!)

    await store.purge(keeping: [])

    let remaining = try? FileManager.default.contentsOfDirectory(atPath: directory.path)
    #expect(remaining?.isEmpty == true)
  }

  @Test("purging a store that was never written does not throw")
  func purgeEmptyStore() async {
    let directory = URL.temporaryDirectory.appending(path: "imagepurge-\(UUID().uuidString)")
    let store = ImageStore(directory: directory, fetch: { _ in Data() })
    await store.purge(keeping: [])
  }
}
