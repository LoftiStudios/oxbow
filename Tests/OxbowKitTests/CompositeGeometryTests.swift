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
  @Test(arguments: ["1920x1080", "1280x720", "854x480", "1146x646"])
  func neverProducesAnOddWidth(resolution: String) throws {
    let geometry = try #require(CompositeGeometry(quality: quality("x", resolution)))
    #expect(geometry.chatWidth.isMultiple(of: 2))
    #expect(geometry.outputWidth.isMultiple(of: 2))
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
}
