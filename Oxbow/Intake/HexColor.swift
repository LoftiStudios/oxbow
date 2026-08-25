import SwiftUI

/// Converts between SwiftUI's `Color` and the hex strings
/// `TwitchDownloaderCLI` takes for chat-render colours.
///
/// The CLI accepts two forms: `#RRGGBB` for an always-opaque colour, and
/// `#AARRGGBB` for one with an alpha channel — alpha comes FIRST, which is
/// not the order most 8-digit hex parsers assume (CSS's 8-digit form is
/// `#RRGGBBAA`). Getting that backwards produces a colour that looks right
/// until it is rendered partially transparent.
nonisolated enum HexColor {

  /// Parses `#RRGGBB` or `#AARRGGBB`. `nil` for anything else: no leading
  /// `#`, a digit count other than 6 or 8, or a non-hex character.
  static func color(fromHex hex: String) -> Color? {
    guard hex.hasPrefix("#") else { return nil }
    let digits = hex.dropFirst()
    guard digits.count == 6 || digits.count == 8, digits.allSatisfy(\.isHexDigit) else {
      return nil
    }
    // `allSatisfy(isHexDigit)` above already rules out the sign and
    // whitespace `UInt32.init(_:radix:)` would otherwise tolerate.
    guard let value = UInt32(digits, radix: 16) else { return nil }

    let red = Double((value >> 16) & 0xFF) / 255
    let green = Double((value >> 8) & 0xFF) / 255
    let blue = Double(value & 0xFF) / 255

    if digits.count == 8 {
      let alpha = Double((value >> 24) & 0xFF) / 255
      return Color(red: red, green: green, blue: blue, opacity: alpha)
    }
    return Color(red: red, green: green, blue: blue, opacity: 1)
  }

  /// Formats a `Color` as `#RRGGBB` when it is fully opaque, or
  /// `#AARRGGBB` — alpha first — when it is not. Round-trips whatever
  /// `color(fromHex:)` produced: a colour parsed from a 6-digit string comes
  /// back opaque and is formatted as 6 digits again.
  static func hex(from color: Color) -> String {
    let resolved = color.resolve(in: EnvironmentValues())
    let alpha = byte(resolved.opacity)
    let red = byte(resolved.red)
    let green = byte(resolved.green)
    let blue = byte(resolved.blue)
    guard alpha == 255 else {
      return String(format: "#%02X%02X%02X%02X", alpha, red, green, blue)
    }
    return String(format: "#%02X%02X%02X", red, green, blue)
  }

  /// Clamped and rounded to a valid 0...255 byte. `Color.Resolved`'s
  /// components can fall outside 0...1 for a wide-gamut colour (Display P3
  /// lets a picker choose one), and an unclamped value would either format
  /// as more than two hex digits or, once negative, as none.
  private static func byte(_ component: Float) -> Int {
    let scaled = (component * 255).rounded()
    return Int(min(max(scaled, 0), 255))
  }
}
