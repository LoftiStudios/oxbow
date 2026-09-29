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
/// Subs, gifts, raids and the other system messages take the CLI's accented layout: a coloured
/// bar, an indent, an icon, and a layout per kind (CR:969-1159). See `Highlight`.
///
/// Badges and emotes are not drawn yet: an emote fragment is drawn as its name, which is also what
/// the CLI does when an emote is missing from its cache.
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
    /// Drawn on a purple band, as a channel-points highlighted message's words are (CR:1619-1623).
    var isBanded = false
  }

  /// The bar and icon of an accented message.
  struct Accent: Sendable {
    let color: ChatColor
    let icon: HighlightIcon?
    let iconColor: ChatColor
  }

  let words: [Word]
  let lineCount: Int
  let accent: Accent?

  /// Height of the comment's section, excluding the gap between comments.
  func height(in style: ChatTextStyle) -> Int { lineCount * style.sectionHeight }

  /// Nil when the CLI would skip the comment (CR:846-869). `index` is the comment's place in
  /// the file, which decides its background; `offset` is its display time from the timeline,
  /// which its timestamp shows.
  init?(
    comment: ChatDocument.Comment, index: Int, offset: Double, style: ChatTextStyle,
    appearance: ChatAppearance)
  {
    guard comment.commenter != nil, let fragments = Self.fragments(of: comment) else {
      return nil
    }
    var builder = Builder(style: style)
    let highlight = Highlight.of(comment)

    if let highlight {
      builder.x = style.sidePadding + style.accentIndent
      builder.lineStart = builder.x
      Self.layoutAccented(
        highlight, comment: comment, fragments: fragments, index: index, offset: offset,
        appearance: appearance, into: &builder)
      accent = Accent(
        color: highlight.accentColor, icon: highlight.icon,
        iconColor: highlight.iconIsPurple ? Highlight.purple : appearance.message)
    } else {
      Self.layoutChat(
        comment: comment, fragments: fragments, index: index, offset: offset,
        appearance: appearance, into: &builder)
      accent = nil
    }

    words = builder.words
    lineCount = builder.line + 1
  }

  /// An ordinary chat line: timestamp, `name:` in its readable colour, then the message
  /// (CR:946-967). Also the viewer's own message under a sub or watch streak.
  private static func layoutChat(
    comment: ChatDocument.Comment, fragments: [ChatDocument.Fragment], index: Int, offset: Double,
    appearance: ChatAppearance, banded: Bool = false, into builder: inout Builder)
  {
    if appearance.hasTimestamps {
      builder.placeTimestamp(Timestamp(seconds: Int(offset)), color: appearance.message)
    }
    let name = comment.commenter?.displayName ?? ""
    let color = appearance.username(UsernameColor.color(for: comment), forComment: index)
    builder.place(name + ":", face: .bold, color: color)
    builder.placeFragments(fragments, color: appearance.message, banded: banded)
  }

  /// CR:982-1159, per kind. Positions at font size 15: the icon at 23; a name or text beside
  /// it at 51 (gifts: 63); the viewer's own message back at 23.
  private static func layoutAccented(
    _ highlight: Highlight, comment: ChatDocument.Comment, fragments: [ChatDocument.Fragment],
    index: Int, offset: Double, appearance: ChatAppearance, into builder: inout Builder)
  {
    let style = builder.style
    let name = comment.commenter?.displayName ?? ""
    let indent = builder.x
    let besideIcon = indent + style.iconSize + style.wordSpacing

    switch highlight {
    case .subscribedTier, .subscribedPrime, .watchStreak, .charityDonation:
      // The name, purple and bold with no colon, beside the icon; the system text always on
      // the next line, hanging under the name (CR:1021-1058, 1095-1150).
      builder.x = besideIcon
      builder.lineStart = besideIcon
      builder.place(name, face: .bold, color: Highlight.purple)
      builder.newLine()
      let split = highlight == .charityDonation
        ? SystemMessage(system: stripName(fragments, count: name.utf16.count + 2), own: nil)
        : SystemMessage.split(
          fragments: stripName(fragments, name: name), body: stripBody(comment.message.body, count: name.utf16.count + 1),
          pattern: highlight == .watchStreak ? .watchStreak : .subscription)
      builder.placeFragments(split.system, color: appearance.message)
      if let own = split.own {
        builder.lineStart = indent
        builder.newLine()
        layoutChat(
          comment: comment, fragments: own, index: index, offset: offset, appearance: appearance,
          into: &builder)
      }

    case .bitsBadgeTier:
      // CR:1060-1093: the name in the message colour, then the CLI's own sentence about the
      // badge, on the same line.
      builder.x = besideIcon
      builder.lineStart = besideIcon
      if fragments.count == 1 {
        builder.place(name, face: .bold, color: appearance.message)
        let version = comment.message.badges.first { $0.name == "bits" }?.version
        builder.placeFragments(
          [ChatDocument.Fragment(text: bitsBadgeSentence(version), emoticonID: nil)],
          color: appearance.message)
      } else {
        builder.place(name + ":", face: .bold, color: appearance.message)
        builder.placeFragments(fragments, color: appearance.message)
      }

    case .giftedSingle, .giftedMany, .giftedAnonymous, .continuingAnonymousGift:
      // CR:1152-1159: the whole body as plain text beside the icon. The CLI indents it by the
      // accent indent less the bar, not by the word gap, so it starts 12 px right of where a
      // sub's name does; kept.
      let giftX = indent + style.iconSize + style.accentIndent - style.accentStroke
      builder.x = giftX
      builder.lineStart = giftX
      builder.placeFragments(fragments, color: appearance.message)

    case .raid, .continuingGift, .payingForward, .combo:
      builder.placeFragments(fragments, color: appearance.message)

    case .channelPoints:
      layoutChat(
        comment: comment, fragments: fragments, index: index, offset: offset,
        appearance: appearance, banded: true, into: &builder)
    }
  }

  /// CR:1075-1084, except that a million bits reads "1M" where the CLI writes "1000K".
  static func bitsBadgeSentence(_ version: String?) -> String {
    guard let version, let amount = Int(version) else { return "just earned a new Bits badge!" }
    let shown = switch amount {
    case 1_000_000...: "\(amount / 1_000_000)M"
    case 1000...: "\(amount / 1000)K"
    default: "\(amount)"
    }
    return "just earned a new \(shown) Bits badge!"
  }

  /// A system message's own text, and the viewer's message that followed it, if any.
  struct SystemMessage {
    let system: [ChatDocument.Fragment]
    let own: [ChatDocument.Fragment]?

    enum Pattern {
      case subscription, watchStreak

      /// HI:49, HI:58.
      var regex: Regex<(Substring, Substring, Substring)> {
        switch self {
        case .subscription:
          /^((?:\w+ )?subscribed (?:with Prime|at Tier \d)\. They've subscribed for \d{1,3} months(?:, currently on a \d{1,3} month streak)?! )(.+)$/
        case .watchStreak:
          /^((?:\w+ )?watched \d+ consecutive streams (?:this month )?and sparked a watch streak! )(.+)$/
        }
      }
    }

    /// HI:291-378, without mutating anything and without the CLI's crash when the message's
    /// fragments do not line up with the text: that case keeps everything as system text.
    static func split(fragments: [ChatDocument.Fragment], body: String, pattern: Pattern) -> SystemMessage {
      guard let match = body.wholeMatch(of: pattern.regex) else {
        return SystemMessage(system: fragments, own: nil)
      }
      let system = [ChatDocument.Fragment(text: String(match.output.1), emoticonID: nil)]
      let own = String(match.output.2)
      guard fragments.count > 1 else {
        return SystemMessage(system: system, own: [ChatDocument.Fragment(text: own, emoticonID: nil)])
      }
      let next = fragments[1].text
      if own.hasOrdinalPrefix(next) {
        return SystemMessage(system: system, own: Array(fragments.dropFirst()))
      }
      guard let range = own.range(of: next), range.lowerBound > own.startIndex else {
        return SystemMessage(system: fragments, own: nil)
      }
      let lead = String(own[..<own.index(before: range.lowerBound)])
      return SystemMessage(
        system: system, own: [ChatDocument.Fragment(text: lead, emoticonID: nil)] + fragments.dropFirst())
    }
  }

  /// CR:1034-1043: the name comes off the front of the first fragment, or the whole first
  /// fragment goes if it is the name.
  private static func stripName(_ fragments: [ChatDocument.Fragment], name: String) -> [ChatDocument.Fragment] {
    guard let first = fragments.first else { return fragments }
    if first.text.caseInsensitiveCompare(name) == .orderedSame { return Array(fragments.dropFirst()) }
    return stripName(fragments, count: name.utf16.count + 1)
  }

  private static func stripName(_ fragments: [ChatDocument.Fragment], count: Int) -> [ChatDocument.Fragment] {
    guard var first = fragments.first else { return fragments }
    first.text = stripBody(first.text, count: count)
    return [first] + fragments.dropFirst()
  }

  private static func stripBody(_ text: String, count: Int) -> String {
    String(text.utf16.dropFirst(count)) ?? ""
  }

  /// The CLI's delimiter set (CR:1162). Runs collapse and ends trim, because empty tokens are
  /// dropped (CR:2209).
  static func isWhitespace(_ character: Character) -> Bool {
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
  struct Builder {
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

    mutating func newLine() {
      line += 1
      x = lineStart
    }

    /// CR:1164-1194: emote fragments whole, everything else split on whitespace, right-to-left
    /// runs reversed, each word placed.
    mutating func placeFragments(_ fragments: [ChatDocument.Fragment], color: ChatColor, banded: Bool = false) {
      let first = words.count
      for fragment in fragments {
        if fragment.emoticonID != nil {
          // CR:1553-1585: a cache miss draws the fragment's text whole, unsplit.
          place(fragment.text, face: .regular, color: color)
          continue
        }
        let tokens = fragment.text.split(whereSeparator: MessageLayout.isWhitespace)
        for token in MessageLayout.rightToLeftReordered(tokens) {
          placeToken(token, color: color)
        }
      }
      if banded {
        for index in first..<words.count { words[index].isBanded = true }
      }
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
