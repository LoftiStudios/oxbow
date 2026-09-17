import Testing
@testable import OxbowKit

@Suite("Download output")
struct DownloadOutputTests {

  /// Pin chat-enabled default output.
  @Test func defaultsToVideoWithChat() {
    #expect(DownloadOutput.default == .videoWithChat)
    #expect(DownloadOutput.allCases.first == .videoWithChat)
  }

  /// Stored in preferences, so the wire names are load-bearing.
  @Test func roundTripsThroughItsRawValue() {
    for output in DownloadOutput.allCases {
      #expect(DownloadOutput(rawValue: output.rawValue) == output)
    }
    #expect(DownloadOutput.videoWithChat.rawValue == "videoWithChat")
    #expect(DownloadOutput.video.rawValue == "video")
  }
}
