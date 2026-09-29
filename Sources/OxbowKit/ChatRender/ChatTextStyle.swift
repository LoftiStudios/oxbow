import CoreGraphics
// CTFont is immutable and documented thread-safe, but not yet annotated Sendable.
@preconcurrency import CoreText
import Foundation

/// The fonts and spacing the CLI derives from `--font-size` and `-w`. Every integer here is the
/// CLI's own truncation of a scaled constant (`ChatRenderOptions.cs`), so they match it exactly;
/// the baseline is the one value that is not derived the same way, see `baseline`.
struct ChatTextStyle: Sendable {
  let width: Int
  let height: Int
  let fontSize: Double
  let regular: CTFont
  let bold: CTFont

  init(width: Int, height: Int, fontSize: Double) {
    self.width = width
    self.height = height
    self.fontSize = fontSize
    regular = Self.inter("Inter-Regular", size: fontSize)
    bold = Self.inter("Inter-Bold", size: fontSize)
  }

  /// CRO:30. Every spacing constant below is written at font size 24.
  private var scale: Double { fontSize / 24 }

  /// One line of a comment (CRO:31). 25 at font size 15.
  var sectionHeight: Int { Int(40 * scale) }
  /// Left inset of every line, and half the right margin (CRO:74). 3 at 15.
  var sidePadding: Int { Int(6 * scale) }
  /// Between comments, never inside one (CRO:75). 15 at 15.
  var verticalPadding: Int { Int(24 * scale) }
  /// After every word, the username included; whitespace itself is never drawn (CRO:76).
  var wordSpacing: Int { Int(6 * scale) }
  /// A word moves to the next line when it would end past this (CR:1637).
  var wrapLimit: Double { Double(width - sidePadding * 2) }

  /// An accented message's bar, and how far its content is indented past it (CRO:78-79).
  var accentStroke: Int { Int(8 * scale) }
  var accentIndent: Int { Int(32 * scale) }
  /// A highlight icon's square, filling the line: 25 at font size 15 (HI:34).
  var iconSize: Int { Int(fontSize / 0.6) }

  /// Between an emoji and whatever follows it (CRO:77).
  var emoteSpacing: Int { Int(6 * scale) }
  /// The square an emoji is drawn into: 22 at font size 15. The CLI rounds half to even
  /// (`Math.Round(22.5)`), which is not Swift's default rounding (CR:2068-2098).
  var emojiSize: Int { Int((36 * scale).rounded(.toNearestOrEven)) }
  /// The box sits this far right of the word's x, and is centred in the line rather than on
  /// the baseline (CR:1355-1356).
  var emojiInset: Int { Int((Double(emoteSpacing) / 2).rounded(.up)) }
  var emojiTop: Int { (sectionHeight - emojiSize) / 2 }

  /// The fixed advance of a timestamp of each length class, measured once from placeholder
  /// digits and truncated, as the CLI caches them (CR:152-158).
  func timestampWidth(_ lengthClass: Int) -> Int {
    let sample = ["0:00", "00:00", "0:00:00", "00:00:00"][min(max(lengthClass, 0), 3)]
    return Int(GlyphRun.width(of: Substring(sample), in: regular))
  }

  /// Baseline from the top of each line. The CLI centres Skia's hinted, rounded-out ink bounds
  /// of "ABC123" in the line (CR:373-375), which measure 15 px tall at font size 15 and give
  /// 20. The height is taken as the font size here — exact at 15, the only size Oxbow uses so
  /// far, and not verified at others.
  var baseline: Int {
    let ink = fontSize.rounded(.down)
    return Int((Double(sectionHeight) - ink) / 2 + ink)
  }

  /// OxbowKit's own resources, where Inter and its licence ship.
  static var resources: Bundle { .module }

  /// Loads one of the Inter faces bundled from the CLI's own resources. A missing font is a
  /// build error in the package, not a state a user can reach, so it falls back to the system
  /// font rather than failing the render.
  private static func inter(_ name: String, size: Double) -> CTFont {
    guard
      let url = Bundle.module.url(forResource: name, withExtension: "ttf", subdirectory: "Fonts"),
      let provider = CGDataProvider(url: url as CFURL),
      let font = CGFont(provider)
    else {
      assertionFailure("\(name).ttf is missing from OxbowKit's resources")
      return CTFontCreateUIFontForLanguage(.system, size, nil)
        ?? CTFontCreateWithName("Helvetica" as CFString, size, nil)
    }
    return CTFontCreateWithGraphicsFont(font, size, nil, nil)
  }
}
