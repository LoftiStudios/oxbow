import Foundation
import Testing
import OxbowKit
@testable import Oxbow

/// `WatchPoller.unseenFindings` — the guard that replaced `WatchPoll.sweep`'s
/// own seen-filter once the sweep started handing over every archive a
/// channel has, seen or not. Not a general `WatchPollerTests` suite, for the
/// same reason `WatchPollerFailedJobFilterTests` is not: the rest of
/// `WatchPoller` is timing and wiring over `QueueHost`'s singleton, verified
/// by hand per `docs/design/channel-watching.md` §9.1. This one function is
/// pure and was pulled out specifically so the single line standing between
/// the rename and Oxbow re-downloading a person's entire archive history
/// could be pinned without a store, a clock, or an engine.
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
