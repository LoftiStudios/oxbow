import Testing
@testable import Oxbow

@Suite("Twitch link")
struct TwitchLinkTests {

  @Test func acceptsACanonicalVideoURL() {
    #expect(TwitchLink.parse("https://www.twitch.tv/videos/2844548319") == .video("2844548319"))
  }

  @Test func acceptsAVideoURLWithQueryParameters() {
    #expect(TwitchLink.parse("https://www.twitch.tv/videos/2844548319?t=1h2m3s") == .video("2844548319"))
  }

  @Test func acceptsAVideoURLWithoutSchemeOrSubdomain() {
    #expect(TwitchLink.parse("twitch.tv/videos/2844548319") == .video("2844548319"))
  }

  @Test func acceptsABareNumericIDAsAVideo() {
    #expect(TwitchLink.parse("2844548319") == .video("2844548319"))
  }

  @Test func trimsSurroundingWhitespace() {
    #expect(TwitchLink.parse("  2844548319\n") == .video("2844548319"))
  }

  @Test func acceptsAChannelClipURL() {
    #expect(TwitchLink.parse("https://www.twitch.tv/leighxp/clip/SomeClipSlug") == .clip("SomeClipSlug"))
  }

  @Test func acceptsAClipURLWithQueryParameters() {
    #expect(TwitchLink.parse("https://www.twitch.tv/leighxp/clip/SomeClipSlug?featured=false") == .clip("SomeClipSlug"))
  }

  @Test func acceptsTheClipsSubdomainForm() {
    #expect(TwitchLink.parse("https://clips.twitch.tv/SomeClipSlug") == .clip("SomeClipSlug"))
  }

  @Test func acceptsABareNonNumericSlugAsAClip() {
    // Clip slugs are Twitch-generated words like "TangibleGiantPancakeKappa".
    #expect(TwitchLink.parse("TangibleGiantPancakeKappa") == .clip("TangibleGiantPancakeKappa"))
  }

  @Test func rejectsEmptyInput() {
    #expect(TwitchLink.parse("   ") == nil)
  }

  @Test func rejectsAChannelURL() {
    #expect(TwitchLink.parse("https://www.twitch.tv/leighxp") == nil)
  }

  @Test func rejectsANonTwitchHost() {
    #expect(TwitchLink.parse("https://evil-twitch.tv/videos/2844548319") == nil)
    #expect(TwitchLink.parse("https://twitch.tv.evil.com/videos/2844548319") == nil)
  }

  @Test func rejectsANonNumericVideoSegment() {
    #expect(TwitchLink.parse("https://www.twitch.tv/videos/notanumber") == nil)
  }
}
