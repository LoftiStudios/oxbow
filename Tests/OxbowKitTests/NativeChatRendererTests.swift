import CoreGraphics
import Foundation
import Testing

@testable import OxbowKit

@Suite("Native chat renderer")
struct NativeChatRendererTests {

  private func document(_ comments: [(name: String, text: String, offset: Int)]) throws -> ChatDocument {
    let entries = comments.enumerated().map { index, comment in
      """
      {"_id": "\(index)", "created_at": "2026-01-01T00:00:\(String(format: "%02d", comment.offset)).000Z",
       "content_offset_seconds": \(comment.offset),
       "commenter": {"display_name": "\(comment.name)", "name": "x"},
       "message": {"body": "\(comment.text)", "fragments": [{"text": "\(comment.text)", "emoticon": null}],
                   "user_color": "#FFFFFF"}}
      """
    }
    let json = """
      {"video": {"start": 0, "end": 10}, "comments": [\(entries.joined(separator: ","))]}
      """
    return try ChatDocument.decode(from: Data(json.utf8))
  }

  private let request = RenderRequest(width: 342, height: 1026, framerate: 30, fontSize: 15)

  /// Rows of the frame, top first, that hold any pixel brighter than the background.
  private func inkedRows(_ image: CGImage) -> [Int] {
    let width = image.width
    let height = image.height
    var pixels = [UInt8](repeating: 0, count: width * height * 4)
    let context = CGContext(
      data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
      space: CGColorSpace(name: CGColorSpace.sRGB)!,
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    return (0..<height).filter { row in
      (0..<width).contains { column in pixels[(row * width + column) * 4] > 0x40 }
    }
  }

  @Test func matchesTheCLIsGeometry() throws {
    let renderer = NativeChatRenderer(document: try document([]), request: request)
    #expect(renderer.size == CGSize(width: 342, height: 1026))
    #expect(renderer.frameCount == 300)
  }

  @Test func showsNothingBeforeTheFirstCommentIsDue() throws {
    let renderer = NativeChatRenderer(
      document: try document([("a", "hello", 2)]), request: request)
    let image = try #require(renderer.frame(index: 0))
    #expect(inkedRows(image).isEmpty)
  }

  /// The newest comment sits at the bottom, one gap above the frame's edge: with 25 px lines
  /// and a 15 px gap its line spans rows 986 to 1010, baseline at 1006.
  @Test func stacksTheNewestCommentAtTheBottom() throws {
    let renderer = NativeChatRenderer(
      document: try document([("a", "hello", 0)]), request: request)
    let rows = inkedRows(try #require(renderer.frame(index: 0)))
    let first = try #require(rows.first)
    let last = try #require(rows.last)
    #expect(first >= 986 && last <= 1010)
  }

  /// Emoji draw through CTLineDraw, which leaves the text position moved; glyphs drawn after it
  /// were offset by it, shifting every word after the first emoji in a frame.
  @Test func anEmojiDoesNotShiftTheWordsDrawnAfterIt() throws {
    let plain = NativeChatRenderer(document: try document([("a", "older", 0)]), request: request)
    let withEmoji = NativeChatRenderer(
      document: try document([("a", "older", 0), ("b", "\u{1F600}", 0)]), request: request)
    // The older comment's line, rows 946 to 970 once the emoji's comment sits below it, must
    // start at the same column as when it is alone at the bottom.
    let plainFrame = try #require(plain.frame(index: 0))
    let emojiFrame = try #require(withEmoji.frame(index: 0))
    let alone = try #require(firstInkedColumn(plainFrame, rows: 986...1010))
    let above = try #require(firstInkedColumn(emojiFrame, rows: 946...970))
    #expect(alone == above)
  }

  private func firstInkedColumn(_ image: CGImage, rows: ClosedRange<Int>) -> Int? {
    let width = image.width
    let height = image.height
    var pixels = [UInt8](repeating: 0, count: width * height * 4)
    let context = CGContext(
      data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
      space: CGColorSpace(name: CGColorSpace.sRGB)!,
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    return (0..<width).first { column in
      rows.contains { row in pixels[(row * width + column) * 4] > 0x40 }
    }
  }

  /// Every script and emoji case in the fixture, with every appearance option on, across the
  /// whole render: nothing fails to draw.
  @Test func drawsTheTextFixtureWithEveryOptionOn() throws {
    let url = try #require(Bundle.module.url(
      forResource: "chat-text-fixtures", withExtension: "json", subdirectory: "Fixtures"))
    let renderer = NativeChatRenderer(
      document: try ChatDocument.decode(from: Data(contentsOf: url)),
      request: RenderRequest(
        width: 342, height: 1026, framerate: 30, fontSize: 15, hasAlternateBackgrounds: true,
        hasTimestamps: true, hasOutline: true))
    for index in stride(from: 0, to: renderer.frameCount, by: 90) {
      #expect(renderer.frame(index: index) != nil)
    }
  }

  /// The CLI aborts the whole render on any character longer than 16 UTF-16 units — a letter
  /// with sixteen combining marks, or a skin-toned family emoji. Here they are just drawn.
  @Test func drawsCharactersTheCLICannot() throws {
    let zalgo = "x" + String(repeating: "\u{0337}", count: 16)
    let family = "\u{1F468}\u{1F3FB}\u{200D}\u{1F469}\u{1F3FB}\u{200D}\u{1F467}\u{1F3FB}\u{200D}\u{1F466}\u{1F3FB}"
    #expect(zalgo.utf16.count == 17 && family.utf16.count == 19)
    let renderer = NativeChatRenderer(
      document: try document([("a", zalgo, 0), ("b", family, 0)]), request: request)
    let rows = inkedRows(try #require(renderer.frame(index: 0)))
    #expect(rows.contains { (946...970).contains($0) })
    #expect(rows.contains { (986...1010).contains($0) })
  }

  /// A word drawn through Core Text's shaped path moves the context's text position, and glyphs
  /// drawn after it are offset by it: every older comment vanished above the frame. Here the
  /// newer comment holds U+034F, which the font cannot draw.
  @Test func aShapedWordDoesNotDisplaceTheCommentsAboveIt() throws {
    let renderer = NativeChatRenderer(
      document: try document([("a", "older", 0), ("b", "newer \u{034F}", 0)]), request: request)
    let rows = inkedRows(try #require(renderer.frame(index: 0)))
    // The older comment's line is one line and one gap above the newer one's: rows 946 to 970.
    #expect(rows.contains { (946...970).contains($0) })
  }
}
