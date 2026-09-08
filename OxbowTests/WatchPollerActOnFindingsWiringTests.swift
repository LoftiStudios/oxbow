import Foundation
import Testing
import OxbowKit
@testable import Oxbow

/// Pins `actOnFindings`'s *wiring* to `Self.unseenFindings` — not the
/// function in isolation, which `WatchPollerUnseenFindingsTests` already
/// covers, but the fact that `actOnFindings` (`WatchPoller.swift:318`) still
/// calls it. Re-inlining `resultsByLogin[watch.login]?.archives ?? []` in
/// its place leaves every other suite green; this is the one test that
/// would catch it (see `.superpowers/sdd/2026-09-07-sweep-returns-all-
/// archives/final-review.md`, finding F1).
///
/// **Why the assertion is on `poller.demotions`, never on submission.**
/// `QueueHost.shared.ready()` genuinely resolves `.ready` under
/// `xcodebuild test` — only `attachStatusObservers` is gated on
/// `AppComposition.isUserSession` (`QueueHost.swift:242`-`243`), not
/// `ready()` itself — so a test that let a `downloadsAutomatically: true`
/// watch reach `AutoDownloadPolicy.decide`'s `.submit` branch could enqueue
/// a real job into the developer's own `queue.json`. There is no path here
/// that can reach `.submit`: both watches below are pinned to `.demoted` or
/// to empty findings, and `actOnFindings` only ever calls
/// `ArchiveSubmission.submit` for entries in `toSubmit`
/// (`WatchPoller.swift:339`-`341`), which neither case populates. Asserting
/// on `poller.demotions` instead is what makes that true by construction
/// rather than by care.
///
/// **How the probe stays deterministic without touching real state.**
/// `AutoDownloadPolicy.decide` returns `.demoted(.belowFloor)` exactly when
/// `downloadable.first` exists (`AutoDownloadPolicy.swift:158`) — i.e. only
/// when findings are non-empty — so whether this watch gets demoted is a
/// direct readout of whether `unseenFindings` ran. But the floor it is
/// measured against is `Preferences().freeSpaceFloor`
/// (`WatchPoller.swift:280`), read from `UserDefaults.standard` with no
/// injected seam — unlike every other reader of `Preferences` in this repo
/// (see that type's own doc comment, and `UpdateModelTests`'s
/// `InMemoryPreferenceStore`), `WatchPoller` gives a test no way to
/// substitute a fake store. Writing to `UserDefaults.standard` to raise the
/// floor was the option the final review flagged as this probe's "wart",
/// and this repo's own convention (`UpdateModelTests.defaults()`'s comment)
/// is to never do that — a suite that touched a real defaults domain once
/// left 1,700 stray files behind. So instead of moving the floor, this
/// shrinks the other side of the comparison to nothing: the archive's
/// `lengthSeconds` is set to a hundred years, which prices it (via
/// `BackfillEstimate`) at hundreds of terabytes — far beyond both the real
/// floor and the real free space on whatever volume the test's own
/// temporary destination sits on, whatever those happen to be on the
/// machine running this test. `availableBytes - cost >= floor` is false by
/// an enormous margin either way, so the result depends only on whether
/// `findings` was empty going in — which is exactly what `unseenFindings`
/// decides.
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

  /// A real, existing directory the destination check can find — created
  /// fresh per test and never written to, since `toSubmit` must stay empty
  /// on both branches below.
  private func existingDestination() throws -> URL {
    let url = URL.temporaryDirectory.appending(path: "poller-wiring-dest-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  private func watch(_ login: String, destination: URL, seen: Set<String>) -> Watch {
    Watch(
      login: login, displayName: login.capitalized,
      settings: Watch.Settings(
        destinationPath: destination.path, qualityCap: .p360,
        output: .video, chatSize: .medium),
      downloadsAutomatically: true, seen: seen)
  }

  /// A feed answering one login with a single archive priced, by
  /// `BackfillEstimate`, at hundreds of terabytes — see this suite's own
  /// doc comment for why that size is the point.
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
    let poller = WatchPoller(
      store: try temporaryStore([watch(login, destination: destination, seen: [archiveID])]),
      feed: feed(archiveID: archiveID))

    await poller.refreshNow()

    // If `unseenFindings` were bypassed, this archive would reach
    // `AutoDownloadPolicy.decide` non-empty and demote on the same floor
    // check the companion test below relies on to fire.
    #expect(poller.demotions[login] == nil)
  }

  @Test("the same watch with nothing seen is demoted, proving the probe fires")
  func emptySeenWatchIsDemoted() async throws {
    let login = "wiring-unseen-\(UUID().uuidString)"
    let archiveID = UUID().uuidString
    let destination = try existingDestination()
    let poller = WatchPoller(
      store: try temporaryStore([watch(login, destination: destination, seen: [])]),
      feed: feed(archiveID: archiveID))

    await poller.refreshNow()

    guard case .belowFloor = poller.demotions[login] else {
      Issue.record("expected .belowFloor, got \(String(describing: poller.demotions[login]))")
      return
    }
  }
}
