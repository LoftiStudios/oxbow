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
}
