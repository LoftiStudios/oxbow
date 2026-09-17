import Foundation
import Testing
@testable import OxbowKit

/// `StreamThumbnail.rewritten(_:)` — pure URL-in, URL-out, so every case here
/// is a plain `#expect` against a hand-built URL rather than a fixture.
@Suite("Stream thumbnail rewrite")
struct StreamThumbnailTests {

  /// Captured VOD URL shape; only the dimensions should change.
  @Test func rewritesAVodFrameToTheTargetSize() {
    let url = URL(string: """
      https://static-cdn.jtvnw.net/cf_vods/d2nvs31859zcd8/\
      5652d9d62faa525b5c68_leighxp_317872278872_1786573193//thumb/thumb0-320x180.jpg
      """)!

    let rewritten = StreamThumbnail.rewritten(url)

    #expect(rewritten.absoluteString == """
      https://static-cdn.jtvnw.net/cf_vods/d2nvs31859zcd8/\
      5652d9d62faa525b5c68_leighxp_317872278872_1786573193//thumb/thumb0-1280x720.jpg
      """)
  }

  /// Every frame index rewrites, not just `thumb0` — the pattern has to
  /// match `\d+` generally, not the literal digit `0`.
  @Test func rewritesEveryFrameIndex() {
    for index in 0...3 {
      let url = URL(string: "https://static-cdn.jtvnw.net/x/thumb/thumb\(index)-320x180.jpg")!
      let rewritten = StreamThumbnail.rewritten(url)
      #expect(rewritten.absoluteString == "https://static-cdn.jtvnw.net/x/thumb/thumb\(index)-1280x720.jpg")
    }
  }

  /// Clip thumbnails have a dash after thumb and must remain unchanged.
  @Test func leavesAClipThumbnailUntouched() {
    let url = URL(string: """
      https://static-cdn.jtvnw.net/twitch-video-assets/\
      twitch-vap-video-assets-prod-us-west-2/c0a947c9-4ed3-4fb0-a7c8-b43160ee371c/\
      landscape/thumb/thumb-0000000000-1920x1080.jpg
      """)!

    #expect(StreamThumbnail.rewritten(url) == url)
  }

  /// Unrecognized URL shapes pass through unchanged.
  @Test func leavesAnUnrelatedURLUntouched() {
    let url = URL(string: "https://example.com/some/other/image.png")!
    #expect(StreamThumbnail.rewritten(url) == url)
  }
}
