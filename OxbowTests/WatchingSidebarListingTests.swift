import Foundation
import Testing
import OxbowKit
@testable import Oxbow

/// `WatchingModel.listings(from:)` — the pure function behind the sidebar's
/// per-channel rows. A `static` over `[Section]` for the same reason
/// `ChannelCard.disconnectedVolume(in:)` is one: it can be exercised without
/// a store, a sweep, or a view.
///
/// **The property that matters most here is that the parent badge is the sum
/// of the children.** `docs/design/watching-navigation.md` §3.2 makes
/// `unreadCount` derive from these listings precisely so the two cannot drift;
/// `parentBadgeIsTheSumOfTheChildren` is the test that keeps that true.
@MainActor
@Suite("Watching sidebar listings")
struct WatchingSidebarListingTests {

  private func archive(_ id: String) -> ChannelArchive {
    ChannelArchive(id: id, title: "Stream \(id)", duration: .seconds(3600),
                   publishedAt: Date(timeIntervalSince1970: 0), status: .recorded,
                   thumbnailURL: nil)
  }

  private func row(_ id: String, _ state: ArchiveRowState) -> WatchingModel.Row {
    WatchingModel.Row(archive: archive(id), state: state)
  }

  private func section(
    _ login: String, displayName: String? = nil, rows: [WatchingModel.Row] = []
  ) -> WatchingModel.Section {
    WatchingModel.Section(
      login: login, displayName: displayName ?? login.capitalized, rows: rows,
      failure: nil, settingsSummary: "Video · Up to 720p · Downloads",
      downloadsAutomatically: false)
  }

  @Test func waitingCountsOnlyAvailableRows() {
    let sections = [
      section("leighxp", rows: [
        row("1", .available),
        row("2", .available),
        row("3", .queued),
        row("4", .running),
        row("5", .downloaded(URL(filePath: "/a.mp4"))),
        row("6", .expired),
        row("7", .failed),
      ])
    ]
    #expect(WatchingModel.listings(from: sections).map(\.waiting) == [2])
  }

  @Test func aChannelWithNothingWaitingReportsZero() {
    // Zero, not absent — the row still exists in the sidebar. Whether a zero
    // draws a badge is the view's decision (it must not), and Task 2 owns it.
    let sections = [section("quiet", rows: [row("1", .queued)])]
    let listings = WatchingModel.listings(from: sections)
    #expect(listings.count == 1)
    #expect(listings[0].waiting == 0)
  }

  @Test func sortsAlphabeticallyByDisplayNameCaseInsensitively() {
    let sections = [
      section("wheelyf", displayName: "WheelyF"),
      section("avabamby", displayName: "AvaBamby"),
      section("middleditch", displayName: "middleditch"),
      section("leighxp", displayName: "LeighXP"),
    ]
    #expect(WatchingModel.listings(from: sections).map(\.displayName)
      == ["AvaBamby", "LeighXP", "middleditch", "WheelyF"])
  }

  @Test func carriesLoginSeparatelyFromDisplayName() {
    // `video-record.md` §3.4: these are two different strings and neither
    // derives from the other. The sidebar shows one and addresses by the other.
    let sections = [section("leighxp", displayName: "LeighXP")]
    let listing = WatchingModel.listings(from: sections)[0]
    #expect(listing.login == "leighxp")
    #expect(listing.displayName == "LeighXP")
    #expect(listing.id == "leighxp")
  }

  @Test func parentBadgeIsTheSumOfTheChildren() {
    let sections = [
      section("a", rows: [row("1", .available), row("2", .available)]),
      section("b", rows: [row("3", .available)]),
      section("c", rows: [row("4", .downloaded(URL(filePath: "/a.mp4")))]),
    ]
    let listings = WatchingModel.listings(from: sections)
    #expect(listings.reduce(0) { $0 + $1.waiting } == 3)
  }

  @Test func noSectionsYieldsNoListings() {
    #expect(WatchingModel.listings(from: []).isEmpty)
  }
}
