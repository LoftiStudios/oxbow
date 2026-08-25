import Foundation
import Testing
@testable import OxbowKit

@Suite("Composite geometry")
struct CompositeGeometryTests {

  private func quality(_ name: String, _ resolution: String) -> StreamQuality {
    StreamQuality(name: name, resolution: resolution, bitsPerSecond: 6_000_000)
  }

  @Test(arguments: [
    ("1080p60", "1920x1080", 360, 2280, 60, 30),
    ("720p60", "1280x720", 240, 1520, 60, 30),
    ("720p30", "1280x720", 240, 1520, 30, 30),
    ("480p30", "854x480", 160, 1014, 30, 30),
  ])
  func derivesEveryDimensionFromTheQuality(
    name: String, resolution: String,
    chatWidth: Int, outputWidth: Int, videoFPS: Int, chatFPS: Int)
    throws
  {
    let geometry = try #require(CompositeGeometry(quality: quality(name, resolution)))
    #expect(geometry.chatWidth == chatWidth)
    #expect(geometry.outputWidth == outputWidth)
    #expect(geometry.videoFramerate == videoFPS)
    #expect(geometry.chatFramerate == chatFPS)
  }

  /// h264_videotoolbox accepts an odd width and SILENTLY CROPS a column —
  /// 1920+351 produced 2270x1080, exit 0, no warning. Verified 2026-08-25.
  @Test(arguments: ["1920x1080", "1280x720", "1146x646"])
  func neverProducesAnOddWidth(resolution: String) throws {
    let geometry = try #require(CompositeGeometry(quality: quality("x", resolution)))
    #expect(geometry.chatWidth.isMultiple(of: 2))
    #expect(geometry.outputWidth.isMultiple(of: 2))
  }

  /// Twitch's metadata dimensions are not always the decoded stream's: h264
  /// 4:2:0 cannot carry an odd coded width or height, so an odd value in
  /// metadata is a rounding artifact, never a real frame. A real download of
  /// `480p30-Portrait` — whose clip-API metadata claims `480x853` — decodes
  /// as `480x852`. `CompositeGeometry.init?` rounds every metadata dimension
  /// down to even as its first step, before deriving anything from it, so
  /// the chat render's height agrees with what the video actually decodes
  /// to — the mismatch `hstack` otherwise refuses outright (§2: exit 234, a
  /// 0-byte output).
  ///
  /// `853x480` (landscape 480p from the clip API) and `480x853` (the
  /// portrait rendition) each round down on the odd axis only; `640x360` and
  /// `1146x646` are already even on both axes and pass through unchanged,
  /// covering the minimum-width clamp and the plain case respectively.
  @Test(arguments: [
    ("1920x1080", 1920, 1080, 360, 2280, 1080),
    ("1280x720", 1280, 720, 240, 1520, 720),
    ("853x480", 852, 480, 160, 1012, 480),
    ("480x853", 480, 852, 160, 640, 852),
    ("640x360", 640, 360, 160, 800, 360),
    ("1146x646", 1146, 646, 214, 1360, 646),
  ])
  func roundsAnOddMetadataDimensionDownToEven(
    resolution: String, videoWidth: Int, videoHeight: Int,
    chatWidth: Int, outputWidth: Int, outputHeight: Int)
    throws
  {
    let geometry = try #require(CompositeGeometry(quality: quality("x", resolution)))
    #expect(geometry.videoWidth == videoWidth)
    #expect(geometry.videoHeight == videoHeight)
    #expect(geometry.chatWidth == chatWidth)
    #expect(geometry.outputWidth == outputWidth)
    #expect(geometry.videoHeight == outputHeight, "the chat's height always equals the video's")
    #expect(geometry.outputWidth.isMultiple(of: 2), "every output width must be even")
    #expect(geometry.videoHeight.isMultiple(of: 2), "every output height must be even")
  }

  /// A clip old enough that Twitch backfilled no framerate is named `720p0`
  /// (see docs/design/chat-and-render.md). `fps=0` is not a filter argument.
  @Test func fallsBackToThirtyWhenTheNameCarriesNoUsableFramerate() throws {
    let zero = try #require(CompositeGeometry(quality: quality("720p0", "1280x720")))
    #expect(zero.videoFramerate == 30)
    let unnamed = try #require(CompositeGeometry(quality: quality("source", "1280x720")))
    #expect(unnamed.videoFramerate == 30)
  }

  /// Upstream's clip names carry suffixes the framerate must survive.
  @Test func readsTheFramerateThroughAClipNameSuffix() throws {
    let geometry = try #require(CompositeGeometry(quality: quality("1080p60-1", "1920x1080")))
    #expect(geometry.videoFramerate == 60)
  }

  /// A clip with no pixel width cannot be composited: the chat's height must
  /// equal the video's, and guessing it produces a silently wrong frame.
  @Test(arguments: ["", "720"])
  func refusesAResolutionWithNoWidth(resolution: String) {
    #expect(CompositeGeometry(quality: quality("720p30", resolution)) == nil)
  }

  /// Never below a legible column.
  @Test func clampsTheChatColumnToAMinimum() throws {
    let tiny = try #require(CompositeGeometry(quality: quality("160p30", "284x160")))
    #expect(tiny.chatWidth == 160)
  }

  // MARK: - Composite bitrate

  /// The exact values from `docs/design/compositing.md` §5, derived on a real
  /// clip (LeighXP, FF7 Rebirth, 1080p60 @ 6128 kbps): the composite's
  /// bitrate corrects the source's own rate for the wider composite frame
  /// (2280/1920 at 1080p) and adds re-encode headroom, rather than passing
  /// the source's bitrate straight through.
  @Test(arguments: [
    (6_128_000, 11),
    (9_685_000, 17),
    (6_184_000, 11),
  ])
  func computesTheCompositeBitrateFromTheSourcesRate(sourceBitsPerSecond: Int, expected: Int)
    throws
  {
    let geometry = try #require(CompositeGeometry(quality: quality("1080p60", "1920x1080")))
    #expect(geometry.compositeBitrateMbps(sourceBitsPerSecond: sourceBitsPerSecond) == expected)
  }

  /// A very low source bitrate must not seed a composite that is unwatchable
  /// on its own — the same 6 Mbps floor the old flat seed used.
  @Test func floorsTheCompositeBitrateAtSix() throws {
    let geometry = try #require(CompositeGeometry(quality: quality("360p30", "640x360")))
    #expect(geometry.compositeBitrateMbps(sourceBitsPerSecond: 100_000) == 6)
  }

  // MARK: - Chat font size

  /// The full nine-cell table from `docs/design/compositing.md` §4: three
  /// standard chat column widths x three sizes.
  @Test(arguments: [
    ("1920x1080", ChatSize.small, 13.0),
    ("1920x1080", ChatSize.medium, 16.0),
    ("1920x1080", ChatSize.large, 20.0),
    ("1280x720", ChatSize.small, 9.0),
    ("1280x720", ChatSize.medium, 11.0),
    ("1280x720", ChatSize.large, 13.0),
    ("854x480", ChatSize.small, 6.0),
    ("854x480", ChatSize.medium, 7.0),
    ("854x480", ChatSize.large, 9.0),
  ])
  func scalesFontSizeToTheChatColumn(resolution: String, size: ChatSize, expected: Double)
    throws
  {
    let geometry = try #require(CompositeGeometry(quality: quality("x", resolution)))
    #expect(geometry.fontSize(for: size) == expected)
  }

  /// Never below a legible size, even for an absurdly narrow column.
  /// `CompositeGeometry.init?` itself never produces one that narrow — it
  /// clamps to `minimumChatWidth` — so this mutates `chatWidth` directly
  /// afterwards to exercise `fontSize(for:)`'s own floor independently of
  /// that clamp, in case the two ever drift apart.
  @Test func neverReturnsAFontSizeBelowOne() throws {
    var geometry = try #require(CompositeGeometry(quality: quality("x", "1920x1080")))
    geometry.chatWidth = 1
    #expect(geometry.fontSize(for: .small) >= 1)
    #expect(geometry.fontSize(for: .medium) >= 1)
    #expect(geometry.fontSize(for: .large) >= 1)
  }
}
