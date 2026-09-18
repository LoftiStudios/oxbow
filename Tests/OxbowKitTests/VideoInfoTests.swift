import Foundation
import Testing
@testable import OxbowKit

@Suite("Video info")
struct VideoInfoTests {

  private func fixture() throws -> String {
    String(decoding: try Fixture.bytes("info-vod-raw.stdout"), as: UTF8.self)
  }

  /// Clip parent checks must not disable VOD chat.
  @Test func aVodAlwaysHasDownloadableChat() throws {
    let info = try #require(VideoInfo.parse(try fixture()))
    #expect(info.hasDownloadableChat)
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

    // Skip the audio-only sixth variant; five video qualities remain.
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

  /// Adversarial quoted CODECS value contains a decoy RESOLUTION attribute. Only top-level
  /// commas may split attributes.
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

  /// Preserve preview URLs from metadata.
  @Test func readsTheFirstThumbnailURL() throws {
    let info = try #require(VideoInfo.parse(try fixture()))
    let thumbnail = try #require(info.thumbnailURL)
    #expect(thumbnail.absoluteString.hasSuffix("/thumb/thumb0-320x180.jpg"))
  }

  /// Preserve all four frames in their original order for the filmstrip.
  @Test func readsAllFourVodThumbnailFrames() throws {
    let info = try #require(VideoInfo.parse(try fixture()))
    #expect(info.thumbnailURLs.count == 4)
    #expect(info.thumbnailURLs.map(\.lastPathComponent) == [
      "thumb0-320x180.jpg", "thumb1-320x180.jpg", "thumb2-320x180.jpg", "thumb3-320x180.jpg",
    ])
  }

  /// Missing or empty previews produce placeholders, not metadata failure.
  @Test func hasNoThumbnailWhenTwitchOffersNone() throws {
    let output = """
      [STATUS] - Fetching Video Info [1/1]
      {"data":{"video":{"title":"t","thumbnailURLs":[],\
      "createdAt":"2026-01-01T00:00:00Z","lengthSeconds":10,\
      "owner":{"displayName":"s"}}}}
      """

    let info = try #require(VideoInfo.parse(output))
    #expect(info.thumbnailURL == nil)
    #expect(info.thumbnailURLs.isEmpty)
  }

  @Test func pixelSizeParsesLandscape() {
    let quality = StreamQuality(name: "1080p60", resolution: "1920x1080", bitsPerSecond: 6_000_000)
    let size = quality.pixelSize
    #expect(size?.width == 1920)
    #expect(size?.height == 1080)
    #expect(quality.shortSide == 1080)
  }

  /// A portrait clip's `1080p` names its **width**. Reading the short side is
  /// what makes the name and the dimensions agree.
  @Test func shortSideReadsPortraitAsItsName() {
    let quality = StreamQuality(
      name: "1080p60-Portrait", resolution: "1080x1920", bitsPerSecond: 6_000_000)
    #expect(quality.shortSide == 1080)
  }

  @Test func pixelSizeIsNilWithoutAResolution() {
    let quality = StreamQuality(name: "720p0-1", resolution: "", bitsPerSecond: 0)
    #expect(quality.pixelSize == nil)
    #expect(quality.shortSide == nil)
  }

  @Test func pixelSizeIsNilWhenNotTwoPositiveIntegers() {
    #expect(StreamQuality(name: "x", resolution: "1920x", bitsPerSecond: 0).pixelSize == nil)
    #expect(StreamQuality(name: "x", resolution: "0x1080", bitsPerSecond: 0).pixelSize == nil)
    #expect(StreamQuality(name: "x", resolution: "1920", bitsPerSecond: 0).pixelSize == nil)
  }

  /// Measured 2026-09-09, helper 1.56.5, VOD 2844787557: `owner` carries
  /// `login` beside `displayName`.
  @Test("a VOD's owner login is parsed")
  func vodOwnerLogin() {
    let payload = """
      {"data":{"video":{"title":"day 46","createdAt":"2026-09-01T12:00:00Z",\
      "lengthSeconds":10203,"owner":{"id":"57692118","displayName":"WheelyF",\
      "login":"wheelyf"},"thumbnailURLs":["https://cdn/a.jpg"]}}}
      #EXTM3U
      """

    let info = VideoInfo.parse(payload)
    #expect(info?.login == "wheelyf")
    #expect(info?.streamer == "WheelyF")
  }

  /// A login that is not the display name lowercased — the case that makes
  /// deriving one from the other wrong rather than merely redundant.
  @Test("a login unrelated to the display name is kept as sent")
  func loginUnrelatedToDisplayName() {
    let payload = """
      {"data":{"video":{"title":"t","createdAt":"2026-09-01T12:00:00Z",\
      "lengthSeconds":60,"owner":{"id":"1","displayName":"日本語配信",\
      "login":"jpstreamer"},"thumbnailURLs":[]}}}
      #EXTM3U
      """

    #expect(VideoInfo.parse(payload)?.login == "jpstreamer")
  }

  /// An older payload without the field must still parse. Nil is honest here;
  /// a guess would not be.
  @Test("an owner with no login parses with a nil login")
  func missingLoginIsNil() {
    let payload = """
      {"data":{"video":{"title":"t","createdAt":"2026-09-01T12:00:00Z",\
      "lengthSeconds":60,"owner":{"displayName":"WheelyF"},"thumbnailURLs":[]}}}
      #EXTM3U
      """

    let info = VideoInfo.parse(payload)
    #expect(info != nil)
    #expect(info?.login == nil)
  }
}

/// Clips use one data.clip JSON object without moments or playlist output.
@Suite("Clip info")
struct ClipInfoTests {

  /// Captured modern clip with landscape/portrait assets and duplicated renditions.
  private func fixture() throws -> String {
    String(decoding: try Fixture.bytes("info-clip-raw.stdout"), as: UTF8.self)
  }

  /// Captured older clip has zero dimensions/rates; infer resolution only from quality and
  /// aspect ratio.
  private func legacyFixture() throws -> String {
    String(decoding: try Fixture.bytes("info-clip-legacy-raw.stdout"), as: UTF8.self)
  }

  /// Use the same parent-video and offset predicate as upstream ChatDownloader on the same
  /// payload, not a correlated metadata field.
  @Test func knowsAModernClipStillHasItsBroadcast() throws {
    let info = try #require(VideoInfo.parse(try fixture()))
    #expect(info.hasDownloadableChat)
  }

  /// The older clip fixture also has an expired parent with both fields null.
  @Test func knowsALegacyClipHasLostItsBroadcast() throws {
    let info = try #require(VideoInfo.parse(try legacyFixture()))
    #expect(!info.hasDownloadableChat)
  }

  @Test func readsTheBroadcasterTitleAndDuration() throws {
    let info = try #require(VideoInfo.parse(try fixture()))

    // Pin broadcaster rather than the separate curator display name.
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

  /// Clip qualities come from assets, not a playlist.
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

  /// Collapse identical duplicate renditions while retaining the first numbered display name.
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
    // Zero frame rate is part of upstream names such as `720p0`.
    #expect(info.qualities.map(\.name) == ["720p0-1", "480p0-1", "360p0-1"])
    #expect(info.qualities.map(\.bitsPerSecond) == [0, 0, 0])
    #expect(info.qualities.map(\.resolution) == ["1280x720", "852x480", "640x360"])
  }

  /// Missing dimensions fall back to quality height and asset aspect ratio.
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

  /// Exercise CDN-path portrait detection without the other two signals.
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

  /// Missing assets still permit naming metadata with an empty quality list.
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

  /// Nested clip.video must not be mistaken for the VOD envelope.
  @Test func theTwoShapesDoNotDecodeAsEachOther() throws {
    let clip = try #require(VideoInfo.parse(try fixture()))
    #expect(clip.streamer == "xQc")

    let vod = try #require(VideoInfo.parse(
      String(decoding: try Fixture.bytes("info-vod-raw.stdout"), as: UTF8.self)))
    #expect(vod.streamer == "LeighXP")
    #expect(vod.qualities.map(\.name) == ["1080p60", "720p60", "480p30", "360p30", "160p30"])
  }

  /// Prefer landscape thumbnail when both orientations exist.
  @Test func readsTheLandscapeAssetsThumbnailURL() throws {
    let info = try #require(VideoInfo.parse(try fixture()))
    let thumbnail = try #require(info.thumbnailURL)
    #expect(thumbnail.absoluteString.contains("/landscape/"))
  }

  /// Clips expose exactly one preview, not a sampled filmstrip.
  @Test func thumbnailURLsIsASingleElementArrayForAClip() throws {
    let info = try #require(VideoInfo.parse(try fixture()))
    #expect(info.thumbnailURLs.count == 1)
    #expect(info.thumbnailURLs.first == info.thumbnailURL)
  }

  /// Portrait-only clips still get their available preview.
  @Test func fallsBackToAPortraitAssetsThumbnailWhenThatIsAllThereIs() throws {
    let output = """
      [STATUS] - Fetching Clip Info [1/1]
      {"data":{"clip":{"title":"t","createdAt":"2026-01-01T00:00:00Z","durationSeconds":10,\
      "broadcaster":{"displayName":"s"},"assets":[{"aspectRatio":0.5625,\
      "thumbnailURL":"https://example.com/portrait/thumb.jpg","portraitMetadata":null,\
      "videoQualities":[{"quality":"1080","frameRate":60,"bitrate":1,"width":1080,"height":1920}]}]}}}
      """

    let info = try #require(VideoInfo.parse(output))
    let thumbnail = try #require(info.thumbnailURL)
    #expect(thumbnail.absoluteString == "https://example.com/portrait/thumb.jpg")
  }

  /// A clip with no assets has no preview either — and still parses, for the
  /// same reason it still offers a name.
  @Test func hasNoThumbnailWhenTheClipHasNoAssets() throws {
    let output = """
      [STATUS] - Fetching Clip Info [1/1]
      {"data":{"clip":{"title":"t","createdAt":"2026-01-01T00:00:00Z","durationSeconds":10,\
      "broadcaster":{"displayName":"s"},"assets":null}}}
      """

    let info = try #require(VideoInfo.parse(output))
    #expect(info.thumbnailURL == nil)
  }
}

/// Pins current CLI suffix normalization. Its original rationale was retracted in
/// `docs/twitch-metadata.md` §5; see the flagged `commandLineValue` comment before changing
/// behavior.
@Suite("Stream quality command line value")
struct StreamQualityCommandLineValueTests {

  private func quality(_ name: String) -> StreamQuality {
    StreamQuality(name: name, resolution: "", bitsPerSecond: 0)
  }

  @Test func leavesAPlainNameUnchanged() {
    #expect(quality("1080p60").commandLineValue == "1080p60")
  }

  @Test func stripsATrailingDisambiguationSuffix() {
    #expect(quality("1080p60-1").commandLineValue == "1080p60")
  }

  @Test func stripsAMultiDigitDisambiguationSuffix() {
    #expect(quality("480p30-2").commandLineValue == "480p30")
  }

  @Test func leavesAPortraitSuffixUnchanged() {
    #expect(quality("1080p60-Portrait").commandLineValue == "1080p60-Portrait")
  }

  @Test func leavesAPortraitSuffixWithAZeroFramerateUnchanged() {
    #expect(quality("1080p0-Portrait").commandLineValue == "1080p0-Portrait")
  }

  /// Current normalization preserves portrait suffixes rather than stripping every trailing
  /// number.
  @Test func leavesAPortraitNameWithItsOwnDisambiguatingSuffixUnchanged() {
    #expect(quality("1080p60-Portrait-1").commandLineValue == "1080p60-Portrait-1")
  }

  @Test func leavesAPortraitNameWithAMultiDigitDisambiguatingSuffixUnchanged() {
    #expect(quality("480p30-Portrait-2").commandLineValue == "480p30-Portrait-2")
  }

  /// In `720p0`, zero is frame rate, not a hyphenated duplicate suffix.
  @Test func doesNotStripABareTrailingDigitThatIsPartOfTheFramerate() {
    #expect(quality("720p0").commandLineValue == "720p0")
  }

  @Test func leavesSourceUnchanged() {
    #expect(quality("source").commandLineValue == "source")
  }

  @Test func leavesAnEmptyNameUnchanged() {
    #expect(quality("").commandLineValue == "")
  }
}
