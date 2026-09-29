import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

@testable import OxbowKit

/// Expected sizes and positions are the CLI's, measured by driving its own `ChatRenderer` on a
/// real `-E` chat at font size 15. Positions are relative to the top-left of the comment.
@Suite("Chat images")
struct ChatImagesTests {

  private let style = ChatTextStyle(width: 342, height: 1026, fontSize: 15)
  private let appearance = ChatAppearance(request: RenderRequest(width: 342, height: 1026, fontSize: 15))

  /// An opaque image of the given size, encoded as the downloader embeds them.
  private static func image(_ width: Int, _ height: Int, type: UTType = .png, frames: [Double] = [0]) -> Data {
    let data = NSMutableData()
    let destination = CGImageDestinationCreateWithData(data, type.identifier as CFString, frames.count, nil)!
    for delay in frames {
      let context = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
      context.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
      context.fill(CGRect(x: 0, y: 0, width: width, height: height))
      let properties = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: delay,
                                                         kCGImagePropertyGIFUnclampedDelayTime: delay]]
      CGImageDestinationAddImage(destination, context.makeImage()!, properties as CFDictionary)
    }
    CGImageDestinationFinalize(destination)
    return data as Data
  }

  private func embedded(
    firstParty: [(id: String, data: Data)] = [], thirdParty: [(name: String, data: Data, zeroWidth: Bool)] = [],
    badges: [(name: String, version: String, data: Data)] = []) -> String
  {
    let first = firstParty.map {
      #"{"id": "\#($0.id)", "imageScale": 2, "data": "\#($0.data.base64EncodedString())", "name": null, "width": 0, "height": 0}"#
    }
    let third = thirdParty.map {
      #"{"id": "x", "imageScale": 2, "data": "\#($0.data.base64EncodedString())", "name": "\#($0.name)", "width": 0, "height": 0, "isZeroWidth": \#($0.zeroWidth)}"#
    }
    let badge = badges.map {
      #"{"name": "\#($0.name)", "versions": {"\#($0.version)": {"title": "t", "description": "d", "bytes": "\#($0.data.base64EncodedString())"}}}"#
    }
    return """
      {"firstParty": [\(first.joined(separator: ","))], "thirdParty": [\(third.joined(separator: ","))],
       "twitchBadges": [\(badge.joined(separator: ","))], "twitchBits": []}
      """
  }

  private func layout(
    _ fragments: String, name: String = "u", badges: String = "[]", embedded: String) throws -> MessageLayout
  {
    let json = """
      {"video": {"start": 0, "end": 1}, "embeddedData": \(embedded), "comments": [{
        "_id": "x", "created_at": "2026-01-01T00:00:00Z", "content_offset_seconds": 0,
        "commenter": {"display_name": "\(name)", "name": "n"},
        "message": {"body": "b", "fragments": \(fragments), "user_color": "#FFFFFF", "user_badges": \(badges)}}]}
      """
    let document = try ChatDocument.decode(from: Data(json.utf8))
    let images = ChatImages(document.embeddedData, fontSize: 15)
    return try #require(MessageLayout(
      comment: document.comments[0], index: 0, offset: 0, style: style, appearance: appearance, images: images))
  }

  private func text(_ words: String) -> String { #"[{"text": "\#(words)", "emoticon": null}]"# }

  private func placements(_ layout: MessageLayout) -> [(x: Int, top: Int, width: Int, height: Int)] {
    layout.words.filter { $0.face == .emote }.map { ($0.x, $0.imageTop, $0.image!.width, $0.image!.height) }
  }

  /// Two 36 px badges at 3 and 26, 22 px square on the line's third row, then the name at 49.
  @Test func drawsBadgesBeforeTheName() throws {
    let badge = Self.image(36, 36)
    let layout = try layout(
      text("hi"), name: "xQcOW", badges: #"[{"_id": "subscriber", "version": "2"}, {"_id": "nasa", "version": "1"}]"#,
      embedded: embedded(badges: [("subscriber", "2", badge), ("nasa", "1", badge)]))
    let badges = layout.words.filter { $0.face == .badge }
    #expect(badges.map(\.x) == [3, 26])
    #expect(badges.map(\.imageTop) == [2, 2])
    #expect(badges.map { $0.image!.width } == [22, 22])
    #expect(layout.words.first { $0.face == .bold }?.x == 49)
  }

  @Test func skipsABadgeTheFileDoesNotHave() throws {
    let layout = try layout(
      text("hi"), badges: #"[{"_id": "nosuch", "version": "1"}, {"_id": "subscriber", "version": "999"}]"#,
      embedded: embedded(badges: [("subscriber", "2", Self.image(36, 36))]))
    #expect(!layout.words.contains { $0.face == .badge })
    #expect(layout.words.first?.x == 3)
  }

  /// A 56 px Twitch emote draws at 35, overhanging its 25 px line by 5 above and below; the old
  /// 48×36 smileys at 29×22.
  @Test func sizesFirstPartyEmotesFromTheirPixels() throws {
    let layout = try layout(
      #"[{"text": "Kappa", "emoticon": {"emoticon_id": "25"}}, {"text": ":)", "emoticon": {"emoticon_id": "1"}}]"#,
      embedded: embedded(firstParty: [("25", Self.image(56, 56)), ("1", Self.image(48, 36))]))
    let placed = placements(layout)
    #expect(placed.map(\.width) == [35, 29])
    #expect(placed.map(\.height) == [35, 22])
    #expect(placed.map(\.top) == [-5, 1])
    #expect(placed.map(\.x) == [20, 58])
  }

  /// `Life ×4`, 120×40 each, after `u:`: two to a line, the second line 8 px up rather than 7 —
  /// the CLI truncates the half pixel toward zero, which rounds the other way on line 0.
  @Test func wrapsWideThirdPartyEmotes() throws {
    let layout = try layout(
      text("Life Life Life Life"), embedded: embedded(thirdParty: [("Life", Self.image(192, 64), false)]))
    let placed = placements(layout)
    #expect(placed.map(\.x) == [20, 143, 3, 126])
    #expect(placed.map(\.top) == [-7, -7, 17, 17])
    #expect(placed.map(\.width) == [120, 120, 120, 120])
    #expect(layout.lineCount == 2)
  }

  @Test func matchesThirdPartyNamesExactly() throws {
    let layout = try layout(
      text("lul LUL LuL LuL,"), embedded: embedded(thirdParty: [("LuL", Self.image(56, 56), false)]))
    #expect(layout.words.filter { $0.face == .emote }.map(\.text) == ["LuL"])
  }

  /// A zero-width emote advances nothing and is right-aligned to what came before it: over a
  /// 35 px base at 20, a 42 px overlay lands at 13.
  @Test func rightAlignsZeroWidthOverlays() throws {
    let layout = try layout(
      text("LuL ZWA end"),
      embedded: embedded(thirdParty: [("LuL", Self.image(56, 56), false), ("ZWA", Self.image(68, 64), true)]))
    let placed = placements(layout)
    #expect(placed.map(\.x) == [20, 13])
    #expect(placed.map(\.top) == [-5, -7])
    #expect(layout.words.last?.x == 58)
  }

  /// A third-party name wins over an emoji of the same text.
  @Test func preferThirdPartyEmotesToEmoji() throws {
    let layout = try layout(text("😀"), embedded: embedded(thirdParty: [("😀", Self.image(56, 56), false)]))
    #expect(layout.words.map(\.face).last == .emote)
  }

  /// Tiers 1, 100, 1000, 5000, 10000, 100000, each a different width so the drawn size says
  /// which tier was chosen: 35, 40, 45, 50, 55, 60 px.
  private func cheerLayout(_ words: String, bits: Int = 100) throws -> MessageLayout {
    let tiers = [(1, 56), (100, 64), (1000, 72), (5000, 80), (10000, 88), (100000, 96)].map { cost, width in
      #""\#(cost)": {"id": "c", "imageScale": 2, "data": "\#(Self.image(width, 56).base64EncodedString())", "name": null, "width": 28, "height": 28}"#
    }
    let embeddedBits = #"{"firstParty": [], "thirdParty": [], "twitchBadges": [], "twitchBits": [{"prefix": "Cheer", "tierList": {\#(tiers.joined(separator: ","))}}]}"#
    let json = """
      {"video": {"start": 0, "end": 1}, "embeddedData": \(embeddedBits), "comments": [{
        "_id": "x", "created_at": "2026-01-01T00:00:00Z", "content_offset_seconds": 0,
        "commenter": {"display_name": "Foobar", "name": "n"},
        "message": {"body": "b", "bits_spent": \(bits), "fragments": \(text(words)), "user_color": "#FFFFFF"}}]}
      """
    let document = try ChatDocument.decode(from: Data(json.utf8))
    return try #require(MessageLayout(
      comment: document.comments[0], index: 0, offset: 0, style: style, appearance: appearance,
      images: ChatImages(document.embeddedData, fontSize: 15)))
  }

  /// `Foobar: Cheer1 nice`: the 35 px tier image at 62, 5 px above the line, and `nice` 38
  /// further on — the CLI's measured positions for a real 56 px tier. The amount is not drawn.
  @Test func drawsACheermoteAsItsTierImage() throws {
    let layout = try cheerLayout("Cheer1 nice")
    let cheer = try #require(layout.words.first { $0.face == .emote })
    #expect(cheer.x == 62 && cheer.imageTop == -5)
    #expect(layout.words.last?.text == "nice" && layout.words.last?.x == 100)
  }

  @Test(arguments: [
    ("Cheer1", 35), ("Cheer99", 35), ("Cheer100", 40), ("Cheer999", 40), ("Cheer1000", 45),
    ("Cheer4999", 45), ("Cheer5000", 50), ("Cheer10000", 55), ("Cheer250000", 60),
    // Below every tier, the first: the renderer does not require a leading 1-9.
    ("Cheer0", 35), ("Cheer007", 35),
  ])
  func choosesTheTierAsTheCLIDoes(word: String, width: Int) throws {
    let layout = try cheerLayout(word)
    #expect(layout.words.first { $0.face == .emote }?.image?.width == width)
  }

  @Test(arguments: ["cheer100", "CHEER100", "Cheer100!", "Cheer1a", "xCheer100", "Cheer99999999999"])
  func leavesAnythingElseAsText(word: String) throws {
    #expect(!(try cheerLayout(word)).words.contains { $0.face == .emote })
  }

  @Test func triesCheermotesOnlyWhenBitsWereSpent() throws {
    #expect(!(try cheerLayout("Cheer100", bits: 0)).words.contains { $0.face == .emote })
  }

  @Test func snapsHeightsAsTheCLIDoes() {
    // 22 is nowhere near a multiple of 36, so nothing moves.
    #expect(ChatImages.snap(22, within: 1, of: 36) == 22)
    // 35 against a 36 px source moves up onto it.
    #expect(ChatImages.snap(35, within: 1, of: 36) == 36)
    #expect(ChatImages.snap(35, within: 0, of: 36) == 35)
  }

  @Test(arguments: [
    ([4, 4, 4], [4, 4, 4]),
    // A frame under 10 ms is held for 100 ms.
    ([0, 3, 3], [10, 3, 3]),
    // All under 20 ms: every frame 100 ms.
    ([1, 1, 1], [10, 10, 10]),
    ([0, 0], [10, 10]),
  ])
  func adjustsFrameDurationsAsTheCLIDoes(raw: [Int], expected: [Int]) {
    #expect(ChatImages.adjusted(raw) == expected)
  }

  /// Delays come from ImageIO's unclamped keys — a zero stays zero there, where the clamped key
  /// reports 100 ms — and a zero is then held for 100 ms by the CLI's own rule. (GIF stores
  /// hundredths, so a 42 ms request is written as 40.)
  @Test func readsAnimatedDelaysUnclamped() throws {
    let gif = Self.image(10, 10, type: .gif, frames: [0.042, 0.03, 0])
    let source = try #require(CGImageSourceCreateWithData(gif as CFData, nil))
    #expect(ChatImages.durations(source, count: 3) == [4, 3, 10])
  }

  /// CR:650-662 on a 25 × 100 ms GIF: the instant a frame ends still shows it. Time is taken
  /// modulo the cycle first, so the end of the cycle is its start again.
  @Test(arguments: [(0, 0), (1, 0), (99, 0), (100, 0), (101, 1), (200, 1), (2499, 24), (2500, 0), (2601, 1)])
  func picksAnimationFramesAsTheCLIDoes(milliseconds: Int, frame: Int) throws {
    let gif = Self.image(10, 10, type: .gif, frames: Array(repeating: 0.1, count: 25))
    let source = try #require(CGImageSourceCreateWithData(gif as CFData, nil))
    let frames = (0..<25).compactMap { CGImageSourceCreateImageAtIndex(source, $0, nil) }
    let image = ChatImage(frames: frames, durations: ChatImages.durations(source, count: 25))
    #expect(image.frameIndex(atMilliseconds: Int64(milliseconds)) == frame)
  }

  /// The CLI's `(long)(tick / 30.0 * 1000)`, not `tick * 100 / 3`: tick 969 is 32,299 ms.
  @Test func runsAnimationOnTheCLIsClock() throws {
    let json = #"{"video": {"start": 0, "end": 60}, "comments": []}"#
    let renderer = NativeChatRenderer(
      document: try ChatDocument.decode(from: Data(json.utf8)),
      request: RenderRequest(width: 342, height: 1026, framerate: 30, fontSize: 15))
    #expect(renderer.animationMilliseconds(forFrame: 969) == 32299)
    #expect(renderer.animationMilliseconds(forFrame: 30) == 1000)
  }

  /// Frames that share a key share their bytes when written. An animated emote on screen must
  /// change the key as it animates, or the file would hold one frame of it.
  @Test func keysFramesByAnimationAsWellAsByComment() throws {
    let gif = Self.image(56, 56, type: .gif, frames: [0.1, 0.1])
    let json = """
      {"video": {"start": 0, "end": 10}, "embeddedData": \(embedded(thirdParty: [("Spin", gif, false)])),
       "comments": [{"_id": "x", "created_at": "2026-01-01T00:00:00Z", "content_offset_seconds": 0,
         "commenter": {"display_name": "u", "name": "n"},
         "message": {"body": "b", "fragments": [{"text": "Spin", "emoticon": null}], "user_color": "#FFFFFF"}}]}
      """
    let renderer = NativeChatRenderer(
      document: try ChatDocument.decode(from: Data(json.utf8)),
      request: RenderRequest(width: 342, height: 1026, framerate: 30, fontSize: 15))
    // 0 ms and 100 ms are frame 0; 133 ms is frame 1.
    #expect(renderer.contentKey(forFrame: 0) == renderer.contentKey(forFrame: 3))
    #expect(renderer.contentKey(forFrame: 0) != renderer.contentKey(forFrame: 4))
  }

  /// A still is copied through unchanged; a downscale is bilinear over premultiplied pixels.
  @Test func resamplesToTheExactSize() throws {
    let source = try #require(CGImageSourceCreateWithData(Self.image(56, 56) as CFData, nil))
    let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
    let scaled = try #require(ChatImages.resample(image, width: 35, height: 35))
    #expect(scaled.width == 35 && scaled.height == 35)
  }
}
