import CoreGraphics
import Foundation
import Testing

@testable import OxbowKit

/// Expected positions come from the CLI's own Skia (SkiaSharp 2.88.9, Inter from its resources),
/// measured at font size 15 — so these also pin that Core Text's unshaped advances for Inter are
/// Skia's.
@Suite("Message layout")
struct MessageLayoutTests {

  private let style = ChatTextStyle(width: 342, height: 1026, fontSize: 15)
  private let plain = ChatAppearance(request: RenderRequest(width: 342, height: 1026, fontSize: 15))

  private func comment(
    name: String = "xQcOW", fragments: String? = #"[{"text": "hello", "emoticon": null}]"#,
    notice: String? = nil, color: String? = "#FFFFFF") throws -> ChatDocument.Comment
  {
    let noticeJSON = notice.map { #", "user_notice_params": {"msg_id": "\#($0)"}"# } ?? ""
    let colorJSON = color.map { "\"\($0)\"" } ?? "null"
    let json = """
      {"video": {"start": 0, "end": 1}, "comments": [{
        "_id": "a", "created_at": "2026-01-01T00:00:00Z", "content_offset_seconds": 0,
        "commenter": {"display_name": "\(name)", "name": "n"},
        "message": {"body": "b", "fragments": \(fragments ?? "null"), "user_color": \(colorJSON)\(noticeJSON)}}]}
      """
    return try ChatDocument.decode(from: Data(json.utf8)).comments[0]
  }

  private func layout(
    _ comment: ChatDocument.Comment, index: Int = 0, offset: Double = 0, appearance: ChatAppearance? = nil)
    throws -> MessageLayout
  {
    try #require(MessageLayout(
      comment: comment, index: index, offset: offset, style: style, appearance: appearance ?? plain))
  }

  private func skips(_ comment: ChatDocument.Comment) -> Bool {
    MessageLayout(comment: comment, index: 0, offset: 0, style: style, appearance: plain) == nil
  }

  @Test func matchesTheCLIsSpacingAtFontSizeFifteen() {
    #expect(style.sectionHeight == 25)
    #expect(style.sidePadding == 3)
    #expect(style.verticalPadding == 15)
    #expect(style.wordSpacing == 3)
    #expect(style.baseline == 20)
    #expect(style.wrapLimit == 336)
  }

  /// Bold "xQcOW:" measures 61.311035 in Skia, so the message starts at 3 + floor(64.311).
  @Test func theMessageStartsAfterTheUsernameAndItsColon() throws {
    let words = try layout(comment()).words
    #expect(words.map(\.text) == ["xQcOW:", "hello"])
    #expect(words.map(\.face) == [.bold, .regular])
    #expect(words.map(\.x) == [3, 67])
    #expect(abs(GlyphRun.width(of: "xQcOW:", in: style.bold) - 61.311035) < 0.001)
    #expect(abs(GlyphRun.width(of: "hello", in: style.regular) - 33.87451) < 0.001)
  }

  /// Whitespace is never drawn, runs collapse and ends trim; each gap is the 3 px spacing, not
  /// the font's space.
  @Test func splitsOnWhitespaceAndDropsEmptyWords() throws {
    let words = try layout(comment(fragments: #"[{"text": "  hello \t hello  ", "emoticon": null}]"#)).words
    #expect(words.map(\.text) == ["xQcOW:", "hello", "hello"])
    // 67 + floor(33.87451 + 3) = 103.
    #expect(words.map(\.x) == [3, 67, 103])
  }

  /// An emote fragment is drawn whole, as the CLI does when the emote is missing from its cache.
  @Test func drawsAnEmoteFragmentAsOneWord() throws {
    let words = try layout(comment(
      fragments: #"[{"text": "two words", "emoticon": {"emoticon_id": "1"}}]"#)).words
    #expect(words.map(\.text) == ["xQcOW:", "two words"])
  }

  @Test func wrapsAWordThatWouldEndPastTheLimit() throws {
    let many = Array(repeating: "hello", count: 12).joined(separator: " ")
    let layout = try layout(comment(fragments: #"[{"text": "\#(many)", "emoticon": null}]"#))
    #expect(layout.lineCount == 2)
    let firstOnSecondLine = try #require(layout.words.first { $0.line == 1 })
    #expect(firstOnSecondLine.x == 3)
    // Everything on the first line ends at or before 336.
    for word in layout.words where word.line == 0 {
      #expect(Double(word.x) + GlyphRun.width(of: Substring(word.text), in: word.face == .bold ? style.bold : style.regular) <= 336)
    }
    #expect(layout.height(in: style) == 50)
  }

  /// A single word wider than a line is cut into pieces that each fit, rather than overflowing.
  @Test func cutsAWordWiderThanALine() throws {
    let long = String(repeating: "abcdefghijklmnopqrstuvwxyz", count: 4)
    let layout = try layout(comment(fragments: #"[{"text": "\#(long)", "emoticon": null}]"#))
    #expect(layout.lineCount >= 2)
    #expect(layout.words.dropFirst().map(\.text).joined() == long)
    for word in layout.words {
      #expect(GlyphRun.width(of: Substring(word.text), in: style.regular) <= 336)
    }
  }

  /// With a `?` or `-` in it, the cut lands just after the last one that fits.
  @Test func cutsALongWordAfterItsLastDelimiter() throws {
    let long = String(repeating: "abcdefgh-", count: 12)
    let layout = try layout(comment(fragments: #"[{"text": "\#(long)", "emoticon": null}]"#))
    let pieces = layout.words.dropFirst().map(\.text)
    #expect(pieces.joined() == long)
    #expect(pieces.dropLast().allSatisfy { $0.hasSuffix("-") })
  }

  @Test func skipsWhatTheCLISkips() throws {
    #expect(skips(try comment(fragments: nil)))
    #expect(skips(try comment(notice: "raid")))
    #expect(!skips(try comment(notice: "resub")))
  }

  /// A highlighted message with no fragments draws its body instead of being skipped.
  @Test func drawsTheBodyOfAHighlightedMessageWithNoFragments() throws {
    let words = try layout(comment(fragments: nil, notice: "highlighted-message")).words
    #expect(words.map(\.text) == ["xQcOW:", "b"])
  }
}

@Suite("Username colour")
struct UsernameColorTests {

  /// Unlike the CLI's per-process hash, the same viewer gets the same default every time.
  @Test func aViewerWithoutAColourGetsAStableDefault() {
    #expect(UsernameColor.fnv1a("xQcOW") == UsernameColor.fnv1a("xQcOW"))
    #expect(UsernameColor.fnv1a("xQcOW") != UsernameColor.fnv1a("xqcow"))
    // FNV-1a's published offset basis: the hash of nothing.
    #expect(UsernameColor.fnv1a("") == 2_166_136_261)
  }
}

@Suite("Chat appearance")
struct ChatAppearanceTests {

  private let style = ChatTextStyle(width: 342, height: 1026, fontSize: 15)

  private func appearance(
    timestamps: Bool = false, outline: Bool = false, alternate: Bool = false) -> ChatAppearance
  {
    ChatAppearance(request: RenderRequest(
      width: 342, height: 1026, fontSize: 15, hasAlternateBackgrounds: alternate,
      hasTimestamps: timestamps, hasOutline: outline))
  }

  private func comment(_ text: String, color: String = "#0000FF") throws -> ChatDocument.Comment {
    let json = """
      {"video": {"start": 0, "end": 1}, "comments": [{
        "_id": "a", "created_at": "2026-01-01T00:00:00Z", "content_offset_seconds": 0,
        "commenter": {"display_name": "xQcOW", "name": "n"},
        "message": {"body": "b", "fragments": [{"text": "\(text)", "emoticon": null}], "user_color": "\(color)"}}]}
      """
    return try ChatDocument.decode(from: Data(json.utf8)).comments[0]
  }

  @Test(arguments: [
    (0, "0:00", 0), (59, "0:59", 0), (600, "10:00", 1), (3599, "59:59", 1),
    (3600, "1:00:00", 2), (36_000, "10:00:00", 3), (90_061, "25:01:01", 3),
  ])
  func formatsTimestampsAsTheCLIDoes(seconds: Int, text: String, lengthClass: Int) {
    let timestamp = Timestamp(seconds: seconds)
    #expect(timestamp.text == text)
    #expect(timestamp.lengthClass == lengthClass)
  }

  /// A timestamp takes a fixed width for its length and twice the word spacing after it, and
  /// wrapped lines start there too: a hanging indent.
  @Test func aTimestampIndentsTheMessageAndItsWrappedLines() throws {
    let many = Array(repeating: "hello", count: 12).joined(separator: " ")
    let layout = try #require(MessageLayout(
      comment: try comment(many), index: 0, offset: 125.4, style: style,
      appearance: appearance(timestamps: true)))
    let indent = 3 + style.timestampWidth(0) + 6
    #expect(layout.words[0].text == "2:05")
    #expect(layout.words[0].x == 3)
    #expect(layout.words[1].x == indent)
    let wrapped = try #require(layout.words.first { $0.line == 1 })
    #expect(wrapped.x == indent)
  }

  /// Against #111111, pure blue is too dark to read and too close to purple: the CLI's own
  /// adjustment gives #0C49F2. With an outline it is read against black instead.
  @Test func makesTheUsernameReadableAgainstWhatItSitsOn() throws {
    let plain = try #require(MessageLayout(
      comment: try comment("hi"), index: 0, offset: 0, style: style, appearance: appearance()))
    #expect(plain.words[0].color == ChatColor(rgb: 0x0C49F2))
    let outlined = try #require(MessageLayout(
      comment: try comment("hi"), index: 0, offset: 0, style: style, appearance: appearance(outline: true)))
    #expect(outlined.words[0].color == ChatColor(rgb: 0x0000FF).readable(against: .black))
  }

  /// Stripes follow the comment's place in the file, not on screen.
  @Test func alternatesBackgroundsByPositionInTheFile() {
    let striped = appearance(alternate: true)
    #expect(striped.background(forComment: 0) == ChatColor(rgb: 0x111111))
    #expect(striped.background(forComment: 1) == ChatColor(rgb: 0x191919))
    #expect(appearance().background(forComment: 1) == ChatColor(rgb: 0x111111))
  }
}

/// The OFL requires Inter's licence to travel with the fonts: it must be in the same bundle.
@Suite("Bundled fonts")
struct BundledFontsTests {

  @Test func shipsInterWithItsLicence() throws {
    for font in ["Inter-Regular", "Inter-Bold"] {
      #expect(ChatTextStyle.resources.url(forResource: font, withExtension: "ttf", subdirectory: "Fonts") != nil)
    }
    let licence = try #require(
      ChatTextStyle.resources.url(forResource: "LICENSE", withExtension: "txt", subdirectory: "Fonts"))
    let text = try String(contentsOf: licence, encoding: .utf8)
    #expect(text.contains("SIL OPEN FONT LICENSE Version 1.1"))
    #expect(text.contains("Copyright (c) 2016 The Inter Project Authors"))
  }
}
