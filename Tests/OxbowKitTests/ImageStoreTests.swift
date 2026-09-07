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
}
