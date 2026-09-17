import Foundation
import Testing
import OxbowKit
@testable import Oxbow

/// Tests the unseen filter used by unattended submissions now that sweeps return all archives.
@Suite("WatchPoller filters findings by seen")
struct WatchPollerUnseenFindingsTests {

  private func watch(_ login: String, seen: Set<String> = []) -> Watch {
    Watch(
      login: login, displayName: login.capitalized,
      settings: .init(destinationPath: "/Users/x/Downloads", qualityCap: .best,
                      output: .videoWithChat, chatSize: .medium),
      downloadsAutomatically: false, seen: seen)
  }

  private func archive(_ id: String) -> ChannelArchive {
    ChannelArchive(id: id, title: "t", duration: .seconds(60),
                   publishedAt: Date(timeIntervalSince1970: 0), status: .recorded, thumbnailURL: nil)
  }

  private func result(_ login: String, _ ids: [String]) -> WatchPollResult {
    WatchPollResult(login: login, displayName: login.capitalized, outcome: .found(ids.map(archive)))
  }

  @Test("an archive already in seen is not offered back")
  func seenArchiveIsExcluded() {
    let resultsByLogin = ["ninja": result("ninja", ["1", "2"])]
    let found = WatchPoller.unseenFindings(
      for: watch("ninja", seen: ["1"]), resultsByLogin: resultsByLogin)
    #expect(found.map(\.id) == ["2"])
  }

  @Test("a watch with nothing seen gets everything the sweep reported for it")
  func emptySeenOffersEverything() {
    let resultsByLogin = ["ninja": result("ninja", ["1", "2"])]
    let found = WatchPoller.unseenFindings(for: watch("ninja"), resultsByLogin: resultsByLogin)
    #expect(found.map(\.id) == ["1", "2"])
  }

  @Test("an archive absent from the sweep is not invented")
  func missingLoginOffersNothing() {
    // No entry for "ninja" at all — a channel this sweep did not cover, the
    // same as `resultsByLogin` looks when a login was stopped mid-sweep.
    let resultsByLogin: [String: WatchPollResult] = ["day9tv": result("day9tv", ["1"])]
    let found = WatchPoller.unseenFindings(for: watch("ninja"), resultsByLogin: resultsByLogin)
    #expect(found.isEmpty)
  }
}
