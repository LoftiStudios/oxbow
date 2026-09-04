import Foundation
import Testing
@testable import OxbowKit

@Suite("ChannelArchive")
struct ChannelArchiveTests {

  @Test("a recorded archive is downloadable")
  func recordedIsDownloadable() {
    let archive = ChannelArchive(
      id: "2862926638", title: "A stream", duration: .seconds(5883),
      publishedAt: Date(timeIntervalSince1970: 0), status: .recorded, thumbnailURL: nil)
    #expect(archive.isDownloadable)
  }

  @Test("a broadcast still in progress is not downloadable")
  func recordingIsNotDownloadable() {
    let archive = ChannelArchive(
      id: "2862926639", title: "Live now", duration: .seconds(60),
      publishedAt: Date(timeIntervalSince1970: 0), status: .recording, thumbnailURL: nil)
    #expect(!archive.isDownloadable)
  }

  @Test("an unrecognised status is not downloadable")
  func unknownIsNotDownloadable() {
    let archive = ChannelArchive(
      id: "1", title: "?", duration: .seconds(1),
      publishedAt: Date(timeIntervalSince1970: 0), status: .other("FAILED"), thumbnailURL: nil)
    #expect(!archive.isDownloadable)
  }
}

/// A `Sendable` box for capturing a value out of an escaping closure.
private final class LockedBox<T>: @unchecked Sendable {
  private let lock = NSLock()
  private var storage: T
  init(_ value: T) { storage = value }
  var value: T {
    get { lock.withLock { storage } }
    set { lock.withLock { storage = newValue } }
  }
}

@Suite("ChannelFeed")
struct ChannelFeedTests {

  /// A feed whose transport returns `body` with `status`, capturing the
  /// request it was given so the query itself can be asserted.
  private func feed(
    body: Data,
    status: Int = 200,
    captured: @escaping @Sendable (URLRequest) -> Void = { _ in })
    -> ChannelFeed
  {
    ChannelFeed(fetch: { request in
      captured(request)
      let response = HTTPURLResponse(
        url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
      return (body, response)
    })
  }

  private func fixture(_ name: String) throws -> Data {
    let url = Bundle.module.url(
      forResource: name, withExtension: "json", subdirectory: "Fixtures")
    return try Data(contentsOf: #require(url))
  }

  @Test("asks for archives only, one page, never paginated")
  func queryShape() async throws {
    let sent = LockedBox<URLRequest?>(nil)
    let feed = feed(body: try fixture("ninja-archives"), captured: { sent.value = $0 })
    _ = try await feed.archives(forLogin: "ninja")

    let request = try #require(sent.value)
    let body = String(decoding: try #require(request.httpBody), as: UTF8.self)
    #expect(body.contains("type: ARCHIVE"))
    #expect(body.contains("first: 100"))
    #expect(!body.contains("after:"))
    #expect(request.value(forHTTPHeaderField: "Client-ID") == ChannelFeed.publicClientID)
    #expect(request.httpMethod == "POST")
  }

  @Test("requests a concrete thumbnail size rather than the placeholder template")
  func thumbnailArguments() async throws {
    let sent = LockedBox<URLRequest?>(nil)
    let feed = feed(body: try fixture("ninja-archives"), captured: { sent.value = $0 })
    _ = try await feed.archives(forLogin: "ninja")

    let body = String(decoding: try #require(sent.value?.httpBody), as: UTF8.self)
    // Without arguments the CDN URL comes back containing a literal
    // "{width}x{height}", which StreamThumbnail's regex cannot match.
    #expect(body.contains("previewThumbnailURL(width: 320, height: 180)"))
  }

  @Test("decodes every node, including statuses it has never seen")
  func decoding() async throws {
    let archives = try await feed(body: try fixture("ninja-archives"))
      .archives(forLogin: "ninja")

    #expect(archives.count == 4)
    #expect(archives[0].id == "2862926638")
    #expect(archives[0].duration == .seconds(5883))
    #expect(archives[0].status == .recorded)
    #expect(archives[2].status == .recording)
    #expect(archives[3].status == .other("TRANSCODING"))
    #expect(archives[2].thumbnailURL == nil)
  }

  @Test("a live broadcast decodes but is not downloadable")
  func liveIsNotDownloadable() async throws {
    let archives = try await feed(body: try fixture("ninja-archives"))
      .archives(forLogin: "ninja")
    #expect(archives.filter(\.isDownloadable).map(\.id) == ["2862926638", "2856555054"])
  }

  @Test("a null user is no such channel, not a failure to parse")
  func nullUser() async throws {
    let body = Data(#"{"data":{"user":null}}"#.utf8)
    await #expect(throws: ChannelFeedError.noSuchChannel) {
      try await feed(body: body).archives(forLogin: "nobody")
    }
  }

  @Test("an integrity challenge is its own error, not a parse failure")
  func integrityChallenge() async throws {
    let body = Data("""
      {"errors":[{"message":"failed integrity check","extensions":{"code":"IntegrityCheckFailed"}}],
       "data":{"user":{"videos":null}}}
      """.utf8)
    await #expect(throws: ChannelFeedError.integrityChallenge) {
      try await feed(body: body).archives(forLogin: "ninja")
    }
  }

  @Test("a non-200 carries its status")
  func serverStatus() async throws {
    await #expect(throws: ChannelFeedError.server(status: 503)) {
      try await feed(body: Data(), status: 503).archives(forLogin: "ninja")
    }
  }

  @Test("unparseable output keeps a bounded snippet")
  func malformedKeepsSnippet() async throws {
    let body = Data(String(repeating: "x", count: 5000).utf8)
    do {
      _ = try await feed(body: body).archives(forLogin: "ninja")
      Issue.record("expected a throw")
    } catch let error as ChannelFeedError {
      guard case .malformedPayload(let snippet) = error else {
        Issue.record("wrong case: \(error)"); return
      }
      // Some room over the raw limit for the truncation marker itself, but
      // nowhere close to the 5000-byte payload — the point being tested.
      #expect(snippet.count <= ChannelFeed.snippetLimit + 64)
      #expect(snippet.count < 5000)
      #expect(snippet.contains("truncated"))
    }
  }

  @Test("a per-node parse failure throws rather than degrading to an empty list")
  func partialParseFailureThrows() async throws {
    // One node undecodable (missing `lengthSeconds`) alongside one good node.
    // `docs/design/channel-watching.md` §7 forbids a silent empty-list
    // degradation here: an empty result is indistinguishable from "nothing
    // new", which is catastrophic combined with `onlyNew` seeding.
    let body = Data("""
      {"data":{"user":{"id":"1","login":"ninja","videos":{"edges":[
        {"node":{"id":"1","title":"ok","lengthSeconds":60,"publishedAt":"2026-01-01T00:00:00Z","status":"RECORDED"}},
        {"node":{"id":"2","title":"missing duration","publishedAt":"2026-01-01T00:00:00Z","status":"RECORDED"}}
      ]}}}}
      """.utf8)
    do {
      _ = try await feed(body: body).archives(forLogin: "ninja")
      Issue.record("expected a throw")
    } catch let error as ChannelFeedError {
      guard case .malformedPayload = error else {
        Issue.record("wrong case: \(error)"); return
      }
    }
  }

  @Test("a legitimately empty edges list still succeeds")
  func emptyEdgesSucceeds() async throws {
    let body = Data(#"{"data":{"user":{"id":"1","login":"ninja","videos":{"edges":[]}}}}"#.utf8)
    let archives = try await feed(body: body).archives(forLogin: "ninja")
    #expect(archives.isEmpty)
  }

  @Test("limit is clamped to the range the server accepts")
  func limitIsClamped() async throws {
    let sent = LockedBox<URLRequest?>(nil)
    let feed = feed(body: try fixture("ninja-archives"), captured: { sent.value = $0 })
    _ = try await feed.archives(forLogin: "ninja", limit: 500)

    let body = String(decoding: try #require(sent.value?.httpBody), as: UTF8.self)
    // The server rejects anything above 100 outright:
    // "argument 'first' value must be between 1 and 100."
    #expect(body.contains("first: 100"))
  }
}
