import Foundation
import Testing
import OxbowKit
@testable import Oxbow

/// The first tests `WatchPoller` has had. They cover the announcement wiring
/// specifically — that a sweep hands `FindingAnnouncement`'s verdict to the
/// notifier once, and carries its answer to the next sweep — not the
/// submission path, which needs a `QueueHost` this cannot stand up.
@MainActor
@Suite("Watch poller announcements")
struct WatchPollerAnnouncementTests {

  private func temporaryStore(_ watches: [Watch]) throws -> WatchStore {
    let store = WatchStore(fileURL: URL.temporaryDirectory
      .appending(path: "poller-\(UUID().uuidString)")
      .appending(path: "watches.json"))
    try store.save(watches)
    return store
  }

  /// `WatchPoller.init` requires a `videoRecordStore` — this suite is not
  /// testing what a sweep records, so each test gets its own disposable file
  /// rather than mentioning what goes through it.
  private func temporaryVideoRecordFile() -> URL {
    URL.temporaryDirectory
      .appending(path: "poller-announcement-video-record-\(UUID().uuidString)")
      .appending(path: "videos.json")
  }

  private func watch(_ login: String, seen: Set<String> = []) -> Watch {
    Watch(login: login, displayName: login.capitalized,
          settings: Watch.Settings(
            destinationPath: "/Users/x/Downloads", qualityCap: .p360,
            output: .video, chatSize: .medium),
          downloadsAutomatically: false, seen: seen)
  }

  /// A feed that answers every login with the given archive ids.
  private func feed(ids: [String]) -> ChannelFeed {
    let nodes = ids.map {
      """
      {"node":{"id":"\($0)","title":"t","lengthSeconds":60,\
      "publishedAt":"2026-01-01T00:00:00Z","status":"RECORDED"}}
      """
    }.joined(separator: ",")
    let body = Data("""
      {"data":{"user":{"id":"1","login":"x","videos":{"edges":[\(nodes)]}}}}
      """.utf8)
    return ChannelFeed(fetch: { request in
      (body, HTTPURLResponse(
        url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    })
  }

  /// Collects what would have been posted, in order.
  private final class Spy: @unchecked Sendable {
    var messages: [FindingAnnouncement.Message] = []
  }

  @Test("a sweep that finds something unseen announces it once")
  func announcesFindings() async throws {
    let spy = Spy()
    let videoRecordFile = temporaryVideoRecordFile()
    defer { try? FileManager.default.removeItem(at: videoRecordFile.deletingLastPathComponent()) }
    let poller = WatchPoller(
      store: try temporaryStore([watch("ninja")]), feed: feed(ids: ["1", "2"]),
      videoRecordStore: VideoRecordStore(fileURL: videoRecordFile),
      announce: { spy.messages.append($0) })

    await poller.refreshNow()

    #expect(spy.messages.count == 1)
    #expect(spy.messages.first?.title == "2 new archives from Ninja")
    #expect(spy.messages.first?.body == "2 archives are waiting in Watching.")
  }

  /// The nag guard, end to end rather than only in `FindingAnnouncement`:
  /// the poller must actually carry the returned set forward, which a unit
  /// test of the pure rule cannot check.
  @Test("a second sweep over the same findings says nothing")
  func doesNotRepeatItself() async throws {
    let spy = Spy()
    let videoRecordFile = temporaryVideoRecordFile()
    defer { try? FileManager.default.removeItem(at: videoRecordFile.deletingLastPathComponent()) }
    let poller = WatchPoller(
      store: try temporaryStore([watch("ninja")]), feed: feed(ids: ["1"]),
      videoRecordStore: VideoRecordStore(fileURL: videoRecordFile),
      announce: { spy.messages.append($0) })

    await poller.refreshNow()
    await poller.refreshNow()

    #expect(spy.messages.count == 1)
  }

  @Test("an archive already in seen is not announced")
  func seenArchivesAreNotFindings() async throws {
    let spy = Spy()
    let videoRecordFile = temporaryVideoRecordFile()
    defer { try? FileManager.default.removeItem(at: videoRecordFile.deletingLastPathComponent()) }
    let poller = WatchPoller(
      store: try temporaryStore([watch("ninja", seen: ["1"])]), feed: feed(ids: ["1"]),
      videoRecordStore: VideoRecordStore(fileURL: videoRecordFile),
      announce: { spy.messages.append($0) })

    await poller.refreshNow()

    #expect(spy.messages.isEmpty)
  }

  @Test("no watches means no sweep and nothing said")
  func emptyWatchListSaysNothing() async throws {
    let spy = Spy()
    let videoRecordFile = temporaryVideoRecordFile()
    defer { try? FileManager.default.removeItem(at: videoRecordFile.deletingLastPathComponent()) }
    let poller = WatchPoller(
      store: try temporaryStore([]), feed: feed(ids: ["1"]),
      videoRecordStore: VideoRecordStore(fileURL: videoRecordFile),
      announce: { spy.messages.append($0) })

    await poller.refreshNow()

    #expect(spy.messages.isEmpty)
    #expect(poller.results.isEmpty)
  }

  /// `refreshNow()` is what the toolbar's Refresh calls, and what
  /// `AddChannelWindow.onSaved` calls so a channel added with automatic
  /// downloading does not sit inert until the next hourly sweep. It must
  /// ignore `WatchPollPolicy`'s throttle — two calls a second apart both
  /// have to reach the network.
  @Test("refreshNow bypasses the hourly throttle")
  func manualRefreshIgnoresTheThrottle() async throws {
    let spy = Spy()
    let fixed = Date(timeIntervalSince1970: 0)
    let videoRecordFile = temporaryVideoRecordFile()
    defer { try? FileManager.default.removeItem(at: videoRecordFile.deletingLastPathComponent()) }
    let poller = WatchPoller(
      store: try temporaryStore([watch("ninja")]), feed: feed(ids: ["1"]),
      videoRecordStore: VideoRecordStore(fileURL: videoRecordFile),
      now: { fixed }, announce: { spy.messages.append($0) })

    await poller.refreshNow()
    #expect(poller.lastPolled == fixed)

    // Same clock, so `shouldPoll` would refuse — but this path never asks it.
    await poller.refreshNow()
    #expect(poller.results.count == 1)
  }
}
