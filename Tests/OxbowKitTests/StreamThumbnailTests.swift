import Foundation
import Testing
@testable import OxbowKit

/// `StreamThumbnail.rewritten(_:)` — pure URL-in, URL-out, so every case here
/// is a plain `#expect` against a hand-built URL rather than a fixture.
@Suite("Stream thumbnail rewrite")
struct StreamThumbnailTests {

  /// The exact shape captured from the live CDN (VOD 2859050150,
  /// 2026-09-01): `thumbN-320x180.jpg` rewrites to `thumbN-1280x720.jpg`,
  /// nothing else in the URL changes.
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

  /// The defect this whole helper exists to avoid: a clip's thumbnail is
  /// already full-size and shaped differently (`thumb-0000000000-WxH.jpg` —
  /// a dash, not a digit, right after `thumb`). It must pass through
  /// byte-for-byte, not get rewritten to a variant that may not exist.
  @Test func leavesAClipThumbnailUntouched() {
    let url = URL(string: """
      https://static-cdn.jtvnw.net/twitch-video-assets/\
      twitch-vap-video-assets-prod-us-west-2/c0a947c9-4ed3-4fb0-a7c8-b43160ee371c/\
      landscape/thumb/thumb-0000000000-1920x1080.jpg
      """)!

    #expect(StreamThumbnail.rewritten(url) == url)
  }

  /// A URL that does not look like either shape at all — the "matches
  /// nothing" case the brief calls out by name.
  @Test func leavesAnUnrelatedURLUntouched() {
    let url = URL(string: "https://example.com/some/other/image.png")!
    #expect(StreamThumbnail.rewritten(url) == url)
  }
}
