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

/// `info --format Raw` for a clip is a different document from a VOD's — one
/// JSON object under `data.clip`, no moments line and no m3u8 section at all —
/// so every one of these would pass against a parser that only knew the VOD
/// shape by failing outright, which is exactly the bug they exist to catch.
@Suite("Clip info")
struct ClipInfoTests {

  /// Captured from the real bundled helper (see the fixtures' README): a
  /// modern clip, with a landscape and a portrait asset, real bitrates and
  /// framerates, and Twitch's habit of listing every rendition twice.
  private func fixture() throws -> String {
    String(decoding: try Fixture.bytes("info-clip-raw.stdout"), as: UTF8.self)
  }

  /// A 2020 clip, captured the same way. Twitch backfills nothing for these:
  /// bitrate, framerate, width and height are all zero, so the whole
  /// resolution-and-estimate path has to survive on the `quality` string and
  /// the asset's aspect ratio alone.
  private func legacyFixture() throws -> String {
    String(decoding: try Fixture.bytes("info-clip-legacy-raw.stdout"), as: UTF8.self)
  }

  @Test func readsTheBroadcasterTitleAndDuration() throws {
    let info = try #require(VideoInfo.parse(try fixture()))

    // Pinned to the captured payload, not merely non-empty: the streamer comes
    // from `clip.broadcaster.displayName`, and the clip payload also carries a
    // `curator.displayName` (whoever clipped it) that is easy to reach for by
    // mistake.
    #expect(info.streamer == "xQc")
    #expect(info.title == "Me on stream")
    #expect(info.duration == .seconds(7))
  }

  @Test func readsCreatedAtAsAnInstant() throws {
    let info = try #require(VideoInfo.parse(try fixture()))

    var components = DateComponents()
    components.year = 2026
    components.month = 8
    components.day = 19
    components.hour = 5
    components.minute = 39
    components.second = 21
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!

    #expect(info.createdAt == calendar.date(from: components))
  }

  /// The clip payload has no m3u8 section, so a parser that looked for one
  /// would produce an empty picker (design doc §6: "Clips carry their own
  /// quality list from the same `info` call").
  @Test func readsQualitiesFromTheClipAssets() throws {
    let info = try #require(VideoInfo.parse(try fixture()))

    #expect(info.qualities.map(\.name) == [
      "1080p60-1", "720p60-1", "480p30-1", "360p30-1",
      "1080p60-Portrait-1", "720p60-Portrait-1", "480p30-Portrait-1", "360p30-Portrait-1",
    ])
  }

  @Test func readsResolutionAndBitrateForEachQuality() throws {
    let info = try #require(VideoInfo.parse(try fixture()))
    let source = try #require(info.qualities.first)

    #expect(source.resolution == "1920x1080")
    #expect(source.bitsPerSecond == 7_970_901)

    // The portrait rendition of the same clip is a genuinely different
    // encode, not a relabelling of the landscape one.
    let portrait = try #require(info.qualities.first { $0.name.hasPrefix("1080p60-Portrait") })
    #expect(portrait.resolution == "1080x1920")
    #expect(portrait.bitsPerSecond == 3_775_053)
  }

  /// Twitch lists each rendition twice. Upstream keeps both and disambiguates
  /// them `-1`/`-2`; we keep the `-1` name (so `-q` still matches exactly) and
  /// drop the identical twin rather than show it.
  @Test func collapsesIdenticalDuplicateRenditions() throws {
    let info = try #require(VideoInfo.parse(try fixture()))

    #expect(info.qualities.count == 8)
    #expect(Set(info.qualities.map(\.name)).count == info.qualities.count)
    #expect(!info.qualities.contains { $0.name.hasSuffix("-2") })
  }

  @Test func listsLandscapeBeforePortraitAndLargestFirst() throws {
    let info = try #require(VideoInfo.parse(try fixture()))
    let portraitIndices = info.qualities.indices.filter {
      info.qualities[$0].name.contains("Portrait")
    }
    let landscapeIndices = info.qualities.indices.filter {
      !info.qualities[$0].name.contains("Portrait")
    }

    #expect(landscapeIndices.max()! < portraitIndices.min()!)
    #expect(info.qualities[landscapeIndices[0]].name == "1080p60-1")
    #expect(info.qualities[portraitIndices[0]].name == "1080p60-Portrait-1")
  }

  @Test func estimatesSizeFromBitrateAndDuration() throws {
    let info = try #require(VideoInfo.parse(try fixture()))
    let source = try #require(info.qualities.first)

    // 7_970_901 bits/s over 7 seconds, in bytes.
    #expect(source.estimatedBytes(over: info.duration) == 6_974_538)
  }

  @Test func readsALegacyClipWithNoBitrateOrFramerate() throws {
    let info = try #require(VideoInfo.parse(try legacyFixture()))

    #expect(info.streamer == "LeighXP")
    #expect(info.title == "Leigh Literally melts")
    #expect(info.duration == .seconds(46))
    // `frameRate` is 0 throughout this payload, so upstream's
    // `{quality}p{frameRate:F0}` really does name them `720p0` — reproduced
    // rather than prettied up, because the name is what `-q` has to match.
    #expect(info.qualities.map(\.name) == ["720p0-1", "480p0-1", "360p0-1"])
    #expect(info.qualities.map(\.bitsPerSecond) == [0, 0, 0])
    #expect(info.qualities.map(\.resolution) == ["1280x720", "852x480", "640x360"])
  }

  /// A clip whose renditions carry no pixel dimensions at all: the height has
  /// to come from the `quality` string and the width from the asset's aspect
  /// ratio (upstream's `BuildClipResolution`).
  @Test func derivesResolutionFromQualityAndAspectRatioWhenDimensionsAreZero() throws {
    let output = """
      [STATUS] - Fetching Clip Info [1/1]
      {"data":{"clip":{"title":"t","createdAt":"2026-01-01T00:00:00Z","durationSeconds":10,\
      "broadcaster":{"displayName":"s"},"assets":[{"aspectRatio":1.7777777777777777,\
      "thumbnailURL":"https://example.com/landscape/x.jpg","portraitMetadata":null,\
      "videoQualities":[{"quality":"720","frameRate":30,"bitrate":0,"width":0,"height":0}]}]}}}
      """

    let info = try #require(VideoInfo.parse(output))
    let quality = try #require(info.qualities.first)
    #expect(quality.name == "720p30")
    #expect(quality.resolution == "1280x720")
  }

  /// Portrait detection has three signals because Twitch populates them
  /// inconsistently. This asset has no `portraitMetadata` and an aspect ratio
  /// that says nothing — only the CDN path gives it away.
  @Test func detectsAPortraitAssetFromItsThumbnailPath() throws {
    let output = """
      [STATUS] - Fetching Clip Info [1/1]
      {"data":{"clip":{"title":"t","createdAt":"2026-01-01T00:00:00Z","durationSeconds":10,\
      "broadcaster":{"displayName":"s"},"assets":[{"aspectRatio":0,\
      "thumbnailURL":"https://example.com/PORTRAIT/x.jpg","portraitMetadata":null,\
      "videoQualities":[{"quality":"720","frameRate":60,"bitrate":1,"width":720,"height":1280}]}]}}}
      """

    let info = try #require(VideoInfo.parse(output))
    #expect(info.qualities.map(\.name) == ["720p60-Portrait"])
  }

  @Test func returnsNilForADeletedClipWhoseDataIsNull() {
    let output = """
      [STATUS] - Fetching Clip Info [1/1]
      {"data":{"clip":null},"extensions":{"durationMilliseconds":12}}
      """
    #expect(VideoInfo.parse(output) == nil)
  }

  /// A clip with no assets is still nameable — the whole point of the fetch is
  /// the filename (design doc §4) — so it parses with an empty quality list
  /// rather than failing and dropping the user back to the raw slug.
  @Test func parsesAClipWithNoAssetsAndOffersNoQualities() throws {
    let output = """
      [STATUS] - Fetching Clip Info [1/1]
      {"data":{"clip":{"title":"t","createdAt":"2026-01-01T00:00:00Z","durationSeconds":10,\
      "broadcaster":{"displayName":"s"},"assets":null}}}
      """

    let info = try #require(VideoInfo.parse(output))
    #expect(info.streamer == "s")
    #expect(info.qualities.isEmpty)
  }

  /// The VOD envelope must not swallow a clip payload and vice versa — the
  /// clip JSON contains a nested `clip.video` object, one wrong key path away
  /// from looking like a VOD.
  @Test func theTwoShapesDoNotDecodeAsEachOther() throws {
    let clip = try #require(VideoInfo.parse(try fixture()))
    #expect(clip.streamer == "xQc")

    let vod = try #require(VideoInfo.parse(
      String(decoding: try Fixture.bytes("info-vod-raw.stdout"), as: UTF8.self)))
    #expect(vod.streamer == "LeighXP")
    #expect(vod.qualities.map(\.name) == ["1080p60", "720p60", "480p30", "360p30", "160p30"])
  }
}
