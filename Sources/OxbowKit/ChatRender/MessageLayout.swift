import CoreGraphics
// CTFont is immutable and documented thread-safe, but not yet annotated Sendable.
@preconcurrency import CoreText
import Foundation

/// One comment laid out the way the CLI lays out plain text: `name:` in bold, then each
/// whitespace-separated word in regular, every word advancing by `floor(width + spacing)`, and a
/// new line whenever a word would end past the wrap limit. Line references are to
/// `ChatRenderer.cs`.
///
/// Text Inter cannot draw — right-to-left scripts, CJK, combining marks — goes to Core Text,
/// with its own shaping, bidi and font fallback. That is deliberately not the CLI's fallback
/// path, which leaves glyphs invisible, detaches combining marks and can abort a render
/// (docs/design/native-chat-render.md §5). What is kept from the CLI is everything that decides
/// where words land: right-to-left word order and the emoji box.
///
/// Badges, emotes and the accented layouts of sub and raid messages are not drawn yet: an emote
/// fragment is drawn as its name, which is also what the CLI does when an emote is missing from
/// its cache.
struct MessageLayout: Sendable {
  struct Word: Sendable {
    enum Face: Sendable { case regular, bold, emoji }

    let text: String
    let face: Face
    let color: ChatColor
    /// Zero-based line within the comment.
    let line: Int
    /// The CLI keeps word origins on whole pixels; glyphs inside a word stay fractional.
    let x: Int
  }

  let words: [Word]
  let lineCount: Int

  /// Height of the comment's section, excluding the gap between comments.
  func height(in style: ChatTextStyle) -> Int { lineCount * style.sectionHeight }

  /// Nil when the CLI would skip the comment (CR:846-869). `index` is the comment's place in
  /// the file, which decides its background; `offset` is its display time from the timeline,
  /// which its timestamp shows.
  init?(
    comment: ChatDocument.Comment, index: Int, offset: Double, style: ChatTextStyle,
    appearance: ChatAppearance)
  {
    guard let commenter = comment.commenter, let fragments = Self.fragments(of: comment) else {
      return nil
    }

    var builder = Builder(style: style)
    if appearance.hasTimestamps {
      builder.placeTimestamp(Timestamp(seconds: Int(offset)), color: appearance.message)
    }
    let username = appearance.username(UsernameColor.color(for: comment), forComment: index)
    builder.place(commenter.displayName + ":", face: .bold, color: username)
    for fragment in fragments {
      if fragment.emoticonID != nil {
        // CR:1553-1585: a cache miss draws the fragment's text whole, unsplit.
        builder.place(fragment.text, face: .regular, color: appearance.message)
        continue
      }
      let tokens = fragment.text.split(whereSeparator: Self.isWhitespace)
      for token in Self.rightToLeftReordered(tokens) {
        builder.placeToken(token, color: appearance.message)
      }
    }

    words = builder.words
    lineCount = builder.line + 1
  }

  /// The CLI's delimiter set (CR:1162). Runs collapse and ends trim, because empty tokens are
  /// dropped (CR:2209).
  private static func isWhitespace(_ character: Character) -> Bool {
    character.unicodeScalars.allSatisfy { scalar in
      switch scalar.value {
      case 0x09...0x0D, 0x20, 0x85, 0xA0, 0x1680, 0x2000...0x200A, 0x2028, 0x2029, 0x202F, 0x205F,
        0x3000:
        true
      default:
        false
      }
    }
  }

  /// CR:2198-2254. Each run of consecutive right-to-left words is reversed, so that drawing
  /// words left to right reads right to left. A word counts by its first UTF-16 unit alone, and
  /// runs never cross a fragment, both as the CLI does it.
  static func rightToLeftReordered<Token: StringProtocol>(_ tokens: [Token]) -> [Token] {
    var result: [Token] = []
    var run: [Token] = []
    for token in tokens {
      if let first = token.utf16.first, (0x0591...0x07FF).contains(first) {
        run.append(token)
      } else {
        result += run.reversed()
        run = []
        result.append(token)
      }
    }
    return result + run.reversed()
  }

  /// Whether the CLI would draw this character as an emoji image rather than text. The CLI asks
  /// its Noto image set; this asks Unicode's emoji properties, which agree on emoji and differ
  /// on 171 symbols such as `©` and `♥`, which Noto has and Unicode presents as text.
  static func isEmoji(_ character: Character) -> Bool {
    let scalars = character.unicodeScalars
    guard let first = scalars.first, first.properties.isEmoji else { return false }
    if scalars.count == 1 { return first.properties.isEmojiPresentation }
    // Sequences: presentation selector, keycap, ZWJ, modifiers, flags and tags.
    return scalars.contains { [0xFE0F, 0x20E3, 0x200D].contains($0.value) }
      || first.properties.isEmojiPresentation
  }

  /// CR:846-869. System notices other than these are skipped; a highlighted message with no
  /// fragments draws its body.
  private static func fragments(of comment: ChatDocument.Comment) -> [ChatDocument.Fragment]? {
    let notice = comment.message.noticeID
    if let notice, !["highlighted-message", "sub", "resub", "subgift", ""].contains(notice) {
      return nil
    }
    if notice == "highlighted-message", comment.message.fragments == nil {
      return [ChatDocument.Fragment(text: comment.message.body, emoticonID: nil)]
    }
    return comment.message.fragments
  }

  /// CR:1589-1644: the placement pass, one word at a time.
  private struct Builder {
    let style: ChatTextStyle
    var words: [Word] = []
    var line = 0
    var x: Int
    /// Where a wrapped line starts: the side padding, or just past a timestamp, which gives
    /// timestamped comments a hanging indent (CR:1956).
    var lineStart: Int

    init(style: ChatTextStyle) {
      self.style = style
      x = style.sidePadding
      lineStart = style.sidePadding
    }

    /// CR:1921-1957. Advanced by a fixed width per length, not its own, so every timestamp of a
    /// length lines its message up at the same x.
    mutating func placeTimestamp(_ timestamp: Timestamp, color: ChatColor) {
      words.append(Word(text: timestamp.text, face: .regular, color: color, line: line, x: x))
      x += style.timestampWidth(timestamp.lengthClass) + style.wordSpacing * 2
      lineStart = x
    }

    /// CR:1294-1376. A word with emoji in it is split: each emoji takes the CLI's fixed box
    /// and advance, and each stretch of text between them is placed as a word of its own, with
    /// its own gap — so `a😀b` spaces out as "a 😀 b", as the CLI draws it.
    mutating func placeToken<Token: StringProtocol>(_ token: Token, color: ChatColor) {
      guard token.contains(where: MessageLayout.isEmoji) else {
        place(String(token), face: .regular, color: color)
        return
      }
      var text = ""
      for character in token {
        guard MessageLayout.isEmoji(character) else {
          text.append(character)
          continue
        }
        if !text.isEmpty {
          place(text, face: .regular, color: color)
          text = ""
        }
        placeEmoji(character)
      }
      if !text.isEmpty {
        place(text, face: .regular, color: color)
      }
    }

    /// CR:1348-1369: wrap when the box would end past the limit, then advance by the box and
    /// the emote spacing — no word gap.
    private mutating func placeEmoji(_ emoji: Character) {
      if x + style.emojiSize > Int(style.wrapLimit) {
        line += 1
        x = lineStart
      }
      words.append(Word(text: String(emoji), face: .emoji, color: .black, line: line, x: x))
      x += style.emojiSize + style.emoteSpacing
    }

    mutating func place(_ text: String, face: Word.Face, color: ChatColor) {
      let font = face == .bold ? style.bold : style.regular
      var remaining = Substring(text)
      var width = GlyphRun.width(of: remaining, in: font)

      // A word wider than a whole line is cut into line-sized pieces first (CR:1593-1606).
      let lineWidth = Double(style.width - style.sidePadding - lineStart)
      while width > lineWidth, !remaining.isEmpty {
        var piece = Self.prefix(of: remaining, fitting: lineWidth, in: font)
        if piece.isEmpty {
          piece = remaining.prefix(1)
        }
        placeWhole(piece, width: GlyphRun.width(of: piece, in: font), face: face, color: color)
        remaining = remaining.dropFirst(piece.count)
        width = GlyphRun.width(of: remaining, in: font)
      }
      placeWhole(remaining, width: width, face: face, color: color)
    }

    private mutating func placeWhole(_ text: Substring, width: Double, face: Word.Face, color: ChatColor) {
      if Double(x) + width > style.wrapLimit {
        line += 1
        x = lineStart
      }
      if !text.isEmpty {
        words.append(Word(text: String(text), face: face, color: color, line: line, x: x))
      }
      x += Int((width + Double(style.wordSpacing)).rounded(.down))
    }

    /// CR:1650-1702. Without `?` or `-`, the longest prefix that fits (Skia's `BreakText`).
    /// With them, a halve-then-grow search, then a cut after the last delimiter in the result.
    private static func prefix(of text: Substring, fitting limit: Double, in font: CTFont) -> Substring {
      guard text.contains(where: { $0 == "?" || $0 == "-" }) else {
        var fitted = 0
        for count in 1...text.count where GlyphRun.width(of: text.prefix(count), in: font) <= limit {
          fitted = count
        }
        return text.prefix(fitted)
      }

      var length = text.count
      repeat { length /= 2 } while length > 0 && GlyphRun.width(of: text.prefix(length), in: font) > limit
      repeat { length += 1 } while length < text.count && GlyphRun.width(of: text.prefix(length), in: font) < limit
      let candidate = text.prefix(max(length - 1, 0))
      if let cut = candidate.lastIndex(where: { $0 == "?" || $0 == "-" }) {
        return candidate[...cut]
      }
      return candidate
    }
  }
}

/// Unshaped glyphs, the way Skia's `MeasureText` and `DrawText` see text: each character's own
/// advance, with no kerning, ligatures or contextual alternates. Core Text shaping would move
/// words and change where lines break.
enum GlyphRun {
  static func glyphs(of text: Substring, in font: CTFont) -> (glyphs: [CGGlyph], advances: [CGSize])? {
    let units = Array(text.utf16)
    guard !units.isEmpty else { return ([], []) }
    // Surrogate pairs and combining marks are not one glyph per unit; the CLI sends those
    // through its fallback path too (CR:1203, `LengthInTextElements() < Length`).
    guard text.count == units.count else { return nil }
    var glyphs = [CGGlyph](repeating: 0, count: units.count)
    guard CTFontGetGlyphsForCharacters(font, units, &glyphs, units.count) else { return nil }
    var advances = [CGSize](repeating: .zero, count: glyphs.count)
    CTFontGetAdvancesForGlyphs(font, .horizontal, glyphs, &advances, glyphs.count)
    return (glyphs, advances)
  }

  /// Advance width. Text the font cannot draw is measured shaped, with system fallback — the
  /// stand-in for the CLI's fallback-font path until phase 1 slice 3 checks it.
  static func width(of text: Substring, in font: CTFont) -> Double {
    if let run = glyphs(of: text, in: font) {
      return run.advances.reduce(0) { $0 + $1.width }
    }
    return CTLineGetTypographicBounds(shapedLine(text, font: font, color: nil), nil, nil, nil)
  }

  static func shapedLine(_ text: Substring, font: CTFont, color: CGColor?) -> CTLine {
    var attributes: [CFString: Any] = [kCTFontAttributeName: font]
    if let color { attributes[kCTForegroundColorAttributeName] = color }
    let string = CFAttributedStringCreate(nil, String(text) as CFString, attributes as CFDictionary)!
    return CTLineCreateWithAttributedString(string)
  }
}
