import Foundation
import Testing
import OxbowKit
@testable import Oxbow

/// Tests the channel-level disconnected-volume notice without constructing a view.
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

  /// If multiple volumes appear, report the first rather than invent a combined result.
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
