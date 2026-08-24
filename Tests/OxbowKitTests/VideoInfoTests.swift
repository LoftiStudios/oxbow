import Foundation
import Testing
@testable import OxbowKit

@Suite("Video info")
struct VideoInfoTests {

  // Reuses the suite's existing loader (Tests/OxbowKitTests/Support/FixtureLoader.swift)
  // rather than a second copy of the same Bundle.module lookup.
  private func fixture() throws -> String {
    String(decoding: try Fixture.bytes("info-vod-raw.stdout"), as: UTF8.self)
  }

  @Test func readsTheStreamerTitleAndDuration() throws {
    let info = try #require(VideoInfo.parse(try fixture()))

    #expect(info.streamer == "LeighXP")
    #expect(!info.title.isEmpty)
    #expect(info.duration > .seconds(0))
  }

  /// The payload escapes non-ASCII as \\uXXXX — `+` arrives as \\u002B — so a
  /// naive substring scrape would leave the escape in the filename.
  @Test func decodesEscapedCharactersInTheTitle() throws {
    let info = try #require(VideoInfo.parse(try fixture()))
    #expect(!info.title.contains("\\u"))
  }

  @Test func readsCreatedAtAsAnInstant() throws {
    let info = try #require(VideoInfo.parse(try fixture()))
    // The fixture's createdAt is a 2026 timestamp; assert it round-tripped as
    // a real date rather than a default.
    #expect(info.createdAt.timeIntervalSince1970 > 1_700_000_000)
  }

  @Test func readsEveryStreamQuality() throws {
    let info = try #require(VideoInfo.parse(try fixture()))

    // The fixture has six #EXT-X-STREAM-INF lines, but the sixth is
    // audio-only (no RESOLUTION attribute) and is deliberately skipped —
    // it is not a video quality a user would pick. Five remain.
    #expect(info.qualities.count == 5)
    let source = try #require(info.qualities.first)
    #expect(source.name == "1080p60")
    #expect(source.resolution == "1920x1080")
    #expect(source.bitsPerSecond == 6_184_466)
  }

  @Test func estimatesSizeFromBitrateAndDuration() throws {
    let info = try #require(VideoInfo.parse(try fixture()))
    let source = try #require(info.qualities.first)

    // bits/s x seconds / 8 = bytes.
    let expected = Int(Double(source.bitsPerSecond) * info.duration.asSeconds / 8)
    #expect(source.estimatedBytes(over: info.duration) == expected)
  }

  @Test func skipsAudioOnlyVariants() throws {
    let info = try #require(VideoInfo.parse(try fixture()))
    #expect(!info.qualities.contains { $0.name == "audio_only" })
  }

  @Test func keepsSourceQualityFirst() throws {
    let info = try #require(VideoInfo.parse(try fixture()))
    #expect(info.qualities.map(\.name) == ["1080p60", "720p60", "480p30", "360p30", "160p30"])
  }

  @Test func returnsNilForOutputThatIsNotInfo() {
    #expect(VideoInfo.parse("") == nil)
    #expect(VideoInfo.parse("[STATUS] - Fetching Video Info [1/1]\nnot json\n") == nil)
  }

  /// Regression guard for the quoted-comma trap: `CODECS`'s value contains a
  /// comma, and (deliberately, adversarially) a decoy `RESOLUTION=1x1` that a
  /// naive `split(",")` would read as a second, later `RESOLUTION` attribute
  /// — overwriting the real one. A quote-aware splitter never sees the decoy
  /// as a top-level attribute at all, because it never leaves the quotes.
  /// Hand-built rather than a second fixture: this is an adversarial case,
  /// not captured output, and should read as one.
  @Test func quoteAwareParsingIgnoresDecoyKeysInsideQuotedValues() throws {
    let output = [
      #"{"data":{"video":{"title":"t","createdAt":"2026-01-01T00:00:00Z","lengthSeconds":10,"owner":{"displayName":"s"}}}}"#,
      "#EXTM3U",
      #"#EXT-X-STREAM-INF:BANDWIDTH=1000000,RESOLUTION=1920x1080,CODECS="avc1.640029,RESOLUTION=1x1",STABLE-VARIANT-ID="test""#,
      "https://example.com/index.m3u8",
    ].joined(separator: "\n")

    let info = try #require(VideoInfo.parse(output))
    let quality = try #require(info.qualities.first)
    #expect(quality.resolution == "1920x1080")
  }

  @Test func returnsNilWhenTheFirstBraceLineFailsToDecode() {
    let output = "[STATUS] - Fetching Video Info [1/1]\n{this is not valid json\n"
    #expect(VideoInfo.parse(output) == nil)
  }

  @Test func returnsNilWhenNoLineLooksLikeJSON() {
    let output = "[STATUS] - Fetching Video Info [1/1]\nno brace-prefixed line here at all\n"
    #expect(VideoInfo.parse(output) == nil)
  }
}
