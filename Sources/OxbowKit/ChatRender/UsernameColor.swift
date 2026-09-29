import CoreGraphics

/// A username's colour: the viewer's own when Twitch recorded one, otherwise one of the CLI's
/// fifteen defaults (CR:33, 1737-1739).
///
/// The CLI picks the default with `string.GetHashCode()`, which .NET randomises per process, so
/// its choice changes on every render (docs/upstream-candidates.md §1). This picks with a stable
/// hash instead: the same palette, one colour per viewer, forever. Matching the CLI here is not
/// possible, only matching its palette.
///
/// Not yet adjusted for contrast against the background, as the CLI's default
/// `--readable-colors` does; that is phase 1 slice 2.
enum UsernameColor {
  static let defaults: [UInt32] = [
    0xFF0000, 0x0000FF, 0x00FF00, 0xB22222, 0xFF7F50, 0x9ACD32, 0xFF4500, 0x2E8B57, 0xDAA520,
    0xD2691E, 0x5F9EA0, 0x1E90FF, 0xFF69B4, 0x8A2BE2, 0x00FF7F,
  ]

  static func color(for comment: ChatDocument.Comment) -> CGColor {
    if let own = comment.message.userColor, let parsed = HexColor.parse(own) {
      return parsed
    }
    let name = comment.commenter?.displayName ?? ""
    return HexColor.color(rgb: defaults[Int(fnv1a(name) % UInt32(defaults.count))])
  }

  /// FNV-1a over UTF-16, as .NET hashes strings, minus the per-process seed.
  static func fnv1a(_ text: String) -> UInt32 {
    var hash: UInt32 = 2_166_136_261
    for unit in text.utf16 {
      hash ^= UInt32(unit)
      hash &*= 16_777_619
    }
    return hash
  }
}

/// Colours as the CLI's arguments and Twitch write them: `#RRGGBB`, or `#AARRGGBB` as Skia reads
/// eight digits.
enum HexColor {
  static func parse(_ text: String) -> CGColor? {
    let digits = text.hasPrefix("#") ? text.dropFirst() : Substring(text)
    guard let value = UInt32(digits, radix: 16) else { return nil }
    switch digits.count {
    case 6:
      return color(rgb: value)
    case 8:
      return color(rgb: value & 0xFF_FFFF, alpha: Double(value >> 24) / 255)
    default:
      return nil
    }
  }

  static func color(rgb: UInt32, alpha: Double = 1) -> CGColor {
    CGColor(
      srgbRed: Double((rgb >> 16) & 0xFF) / 255,
      green: Double((rgb >> 8) & 0xFF) / 255,
      blue: Double(rgb & 0xFF) / 255,
      alpha: alpha)
  }
}
