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
