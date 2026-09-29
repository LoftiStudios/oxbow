import Foundation
import Testing

@testable import OxbowKit

/// Text Inter cannot draw. Expected positions are the CLI's, measured by driving its own
/// `ChatRenderer` at font size 15.
@Suite("Fallback layout")
struct FallbackLayoutTests {

  private let style = ChatTextStyle(width: 342, height: 1026, fontSize: 15)
  private let appearance = ChatAppearance(request: RenderRequest(width: 342, height: 1026, fontSize: 15))

  private func words(_ text: String, name: String = "a") throws -> [MessageLayout.Word] {
    let json = """
      {"video": {"start": 0, "end": 1}, "comments": [{
        "_id": "x", "created_at": "2026-01-01T00:00:00Z", "content_offset_seconds": 0,
        "commenter": {"display_name": "\(name)", "name": "n"},
        "message": {"body": "b", "fragments": [{"text": "\(text)", "emoticon": null}], "user_color": "#FFFFFF"}}]}
      """
    let comment = try ChatDocument.decode(from: Data(json.utf8)).comments[0]
    let layout = try #require(MessageLayout(
      comment: comment, index: 0, offset: 0, style: style, appearance: appearance))
    return Array(layout.words.dropFirst())
  }

  @Test func matchesTheCLIsEmojiBoxAtFontSizeFifteen() {
    #expect(style.emojiSize == 22)
    #expect(style.emoteSpacing == 3)
    #expect(style.emojiInset == 2)
    #expect(style.emojiTop == 1)
  }

  @Test(arguments: [
    ("😀", true), ("👍🏽", true), ("👨‍👩‍👧‍👦", true), ("🇺🇸", true), ("1️⃣", true), ("❤️", true),
    ("1", false), ("#", false), ("a", false), ("★", false), ("❤", false), ("©", false),
  ])
  func decidesWhatIsAnEmoji(text: String, isEmoji: Bool) throws {
    #expect(MessageLayout.isEmoji(try #require(text.first)) == isEmoji)
  }

  /// A combining mark after a space starts a word of its own, as the CLI's code-unit split has
  /// it; Swift's characters would glue it to the space and the word before it.
  @Test func splitsWordsOnScalarsNotCharacters() {
    #expect(MessageLayout.words(in: "Aware \u{034F}") == ["Aware", "\u{034F}"])
    #expect(MessageLayout.words(in: "  a \t b  ") == ["a", "b"])
  }

  /// `A B ר1 ר2 ר3 C ר4` becomes `A B ר3 ר2 ר1 C ר4`: runs reverse, LTR words are barriers.
  @Test func reversesEachRunOfRightToLeftWords() {
    let tokens = ["A", "B", "ר1", "ר2", "ר3", "C", "ר4"]
    #expect(MessageLayout.rightToLeftReordered(tokens) == ["A", "B", "ר3", "ר2", "ר1", "C", "ר4"])
    // First UTF-16 unit only: a word opening with a digit or bracket is left to right.
    #expect(MessageLayout.rightToLeftReordered(["123שלום", "(שלום)"]) == ["123שלום", "(שלום)"])
  }

  /// `a😀b`: `a` advances floor(8.42 + 3) = 11, the emoji a fixed 25, then `b`, each text span
  /// with its own gap. Measured endX in the CLI: 51 after a 3 px start.
  @Test func splitsTextAroundAnEmojiWithTheCLIsGaps() throws {
    let placed = try words("a😀b")
    #expect(placed.map(\.text) == ["a", "😀", "b"])
    #expect(placed.map(\.face) == [.regular, .emoji, .regular])
    let start = try #require(placed.first).x
    #expect(placed.map(\.x) == [start, start + 11, start + 36])
  }

  /// Thirteen emoji fit on a line from x = 3: the fourteenth would end past 336.
  @Test func wrapsEmojiThirteenToALine() throws {
    let placed = try words(String(repeating: "😀", count: 15), name: "")
    let lines = Dictionary(grouping: placed.filter { $0.face == .emoji }, by: \.line)
    #expect(lines[0]?.count == 13)
    #expect(lines[1]?.count == 2)
    #expect(lines[1]?.first?.x == 3)
  }

  /// Emoji tokens separated by whitespace advance exactly as run-together ones: no word gap.
  @Test func addsNoWordGapBetweenEmoji() throws {
    let spaced = try words("😀 😀").map(\.x)
    let joined = try words("😀😀").map(\.x)
    #expect(spaced == joined)
    #expect(spaced[1] - spaced[0] == 25)
  }
}
