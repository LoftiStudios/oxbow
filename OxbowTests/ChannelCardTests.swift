import Foundation
import Testing
import OxbowKit
@testable import Oxbow

/// `ChannelCard.disconnectedVolume(in:)` — the pure function behind the
/// channel-level notice `docs/design/channel-history.md` §4.2 asks for.
/// Pulled out to a `static` function (the same move `NotificationDecision`
/// and `ArchiveRowState` already make) so this can be exercised without
/// building a view.
@Suite("Channel card disconnected volume")
struct ChannelCardTests {

  private func archive(_ id: String) -> ChannelArchive {
    ChannelArchive(id: id, title: "Stream \(id)", duration: .seconds(3600),
                   publishedAt: Date(timeIntervalSince1970: 0), status: .recorded,
                   thumbnailURL: nil)
  }

  private func row(_ id: String, _ state: ArchiveRowState) -> WatchingModel.Row {
    WatchingModel.Row(archive: archive(id), state: state)
  }

  @Test func noUnverifiableRowsYieldsNil() {
    let rows = [row("1", .available), row("2", .downloaded(URL(filePath: "/a.mp4")))]
    #expect(ChannelCard.disconnectedVolume(in: rows) == nil)
  }

  @Test func oneUnverifiableRowYieldsItsVolume() {
    let rows = [
      row("1", .available),
      row("2", .unverifiable(volumeName: "Helios")),
    ]
    #expect(ChannelCard.disconnectedVolume(in: rows) == "Helios")
  }

  /// Two different volumes is not a state a person should ever actually see —
  /// one channel has one destination — but the function must not paper over
  /// it with a summary it never computed. It names the first and stops.
  @Test func twoDifferentVolumesYieldsTheFirstAndInventsNoSummary() {
    let rows = [
      row("1", .unverifiable(volumeName: "Helios")),
      row("2", .unverifiable(volumeName: "Storage")),
    ]
    #expect(ChannelCard.disconnectedVolume(in: rows) == "Helios")
  }

  @Test func emptyRowsYieldsNil() {
    #expect(ChannelCard.disconnectedVolume(in: []) == nil)
  }
}
