import Testing
@testable import Oxbow

@Suite("Twitch video URL")
struct TwitchVideoURLTests {

  @Test func acceptsACanonicalVideoURL() {
    #expect(TwitchVideoURL.videoID(from: "https://www.twitch.tv/videos/2844548319") == "2844548319")
  }

  @Test func acceptsAURLWithQueryParameters() {
    #expect(TwitchVideoURL.videoID(from: "https://www.twitch.tv/videos/2844548319?t=1h2m3s") == "2844548319")
  }

  @Test func acceptsAURLWithoutSchemeOrSubdomain() {
    #expect(TwitchVideoURL.videoID(from: "twitch.tv/videos/2844548319") == "2844548319")
  }

  @Test func acceptsABareNumericID() {
    #expect(TwitchVideoURL.videoID(from: "2844548319") == "2844548319")
  }

  @Test func trimsSurroundingWhitespace() {
    #expect(TwitchVideoURL.videoID(from: "  2844548319\n") == "2844548319")
  }

  @Test func rejectsEmptyInput() {
    #expect(TwitchVideoURL.videoID(from: "   ") == nil)
  }

  @Test func rejectsAClipURL() {
    #expect(TwitchVideoURL.videoID(from: "https://www.twitch.tv/someone/clip/SomeSlug") == nil)
  }

  @Test func rejectsAChannelURL() {
    #expect(TwitchVideoURL.videoID(from: "https://www.twitch.tv/leighxp") == nil)
  }

  @Test func rejectsANonNumericVideoSegment() {
    #expect(TwitchVideoURL.videoID(from: "https://www.twitch.tv/videos/notanumber") == nil)
  }
}
