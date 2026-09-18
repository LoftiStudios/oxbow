import Foundation
import Testing
import OxbowKit
@testable import Oxbow

/// Tests that `actOnFindings` uses unseen filtering through its demotion result. Never allow
/// submission: the shared QueueHost can resolve a real engine under hosted tests. A
/// hundred-year archive prices far beyond available space, forcing demotion without changing
/// real preferences; an already-seen archive must instead produce no findings.
@MainActor
@Suite("Watch poller wires unseenFindings into actOnFindings")
struct WatchPollerActOnFindingsWiringTests {

  private func temporaryStore(_ watches: [Watch]) throws -> WatchStore {
    let store = WatchStore(fileURL: URL.temporaryDirectory
      .appending(path: "poller-wiring-\(UUID().uuidString)")
      .appending(path: "watches.json"))
    try store.save(watches)
    return store
  }

  /// Existing temporary destination; no submission may write into it.
  private func existingDestination() throws -> URL {
    let url = URL.temporaryDirectory.appending(path: "poller-wiring-dest-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  /// Disposable record store unrelated to the behavior under test.
  private func temporaryVideoRecordFile() -> URL {
    URL.temporaryDirectory
      .appending(path: "poller-wiring-video-record-\(UUID().uuidString)")
      .appending(path: "videos.json")
  }

  private func watch(_ login: String, destination: URL, seen: Set<String>) -> Watch {
    Watch(
      login: login, displayName: login.capitalized,
      settings: Watch.Settings(
        destinationPath: destination.path, qualityCap: .p360,
        output: .video, chatSize: .medium),
      downloadsAutomatically: true, seen: seen)
  }

  /// Oversized archive forces demotion rather than real submission; see the suite comment.
  private func feed(archiveID: String) -> ChannelFeed {
    let centuryInSeconds = 100 * 365 * 24 * 60 * 60
    let body = Data("""
      {"data":{"user":{"id":"1","login":"x","videos":{"edges":[\
      {"node":{"id":"\(archiveID)","title":"t","lengthSeconds":\(centuryInSeconds),\
      "publishedAt":"2026-01-01T00:00:00Z","status":"RECORDED"}}\
      ]}}}}
      """.utf8)
    return ChannelFeed(fetch: { request in
      (body, HTTPURLResponse(
        url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    })
  }

  @Test("an automatic watch whose finding is already seen is not demoted")
  func fullySeenWatchIsNotDemoted() async throws {
    let login = "wiring-seen-\(UUID().uuidString)"
    let archiveID = UUID().uuidString
    let destination = try existingDestination()
    let videoRecordFile = temporaryVideoRecordFile()
    defer { try? FileManager.default.removeItem(at: videoRecordFile.deletingLastPathComponent()) }
    let poller = WatchPoller(
      store: try temporaryStore([watch(login, destination: destination, seen: [archiveID])]),
      feed: feed(archiveID: archiveID),
      videoRecordStore: VideoRecordStore(fileURL: videoRecordFile))

    await poller.refreshNow()

    // Bypassing unseen filtering would demote this watch.
    #expect(poller.demotions[login] == nil)
  }

  @Test("the same watch with nothing seen is demoted, proving the probe fires")
  func emptySeenWatchIsDemoted() async throws {
    let login = "wiring-unseen-\(UUID().uuidString)"
    let archiveID = UUID().uuidString
    let destination = try existingDestination()
    let videoRecordFile = temporaryVideoRecordFile()
    defer { try? FileManager.default.removeItem(at: videoRecordFile.deletingLastPathComponent()) }
    let poller = WatchPoller(
      store: try temporaryStore([watch(login, destination: destination, seen: [])]),
      feed: feed(archiveID: archiveID),
      videoRecordStore: VideoRecordStore(fileURL: videoRecordFile))

    await poller.refreshNow()

    guard case .belowFloor = poller.demotions[login] else {
      Issue.record("expected .belowFloor, got \(String(describing: poller.demotions[login]))")
      return
    }
  }
}
