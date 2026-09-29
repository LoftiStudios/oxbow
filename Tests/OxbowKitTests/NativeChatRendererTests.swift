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
