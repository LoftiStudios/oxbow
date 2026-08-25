import SwiftUI
import Testing
@testable import Oxbow

@Suite("Hex colour")
struct HexColorTests {

  // MARK: - Parsing

  @Test func sixDigitParsesAsOpaque() throws {
    let color = try #require(HexColor.color(fromHex: "#111111"))
    let resolved = color.resolve(in: EnvironmentValues())
    #expect(abs(Double(resolved.opacity) - 1) < 0.01)
    #expect(componentsMatch(resolved, red: 0x11, green: 0x11, blue: 0x11))
  }

  /// The order the CLI documents is alpha FIRST — `#AARRGGBB`, not the
  /// `#RRGGBBAA` most 8-digit hex parsers assume. A wrong implementation
  /// that reads this as `#RRGGBBAA` decodes alpha as `0x00` (fully
  /// transparent) instead of `0xC8`, and red as `0xC8` instead of `0xFF` —
  /// every assertion below would catch that swap.
  @Test func eightDigitReadsAlphaFirst() throws {
    let color = try #require(HexColor.color(fromHex: "#C8FF0059"))
    let resolved = color.resolve(in: EnvironmentValues())
    #expect(abs(Double(resolved.opacity) - 200.0 / 255.0) < 0.01)
    #expect(componentsMatch(resolved, red: 0xFF, green: 0x00, blue: 0x59))
  }

  @Test func missingHashIsRejected() {
    #expect(HexColor.color(fromHex: "111111") == nil)
  }

  @Test(arguments: [
    "#1234",        // four digits, too short for either form
    "#12345",       // between the two valid lengths
    "#1234567",     // between the two valid lengths, the other side
    "#123456789",   // longer than either valid form
    "",             // empty
    "#",            // just the hash
  ])
  func wrongLengthIsRejected(_ hex: String) {
    #expect(HexColor.color(fromHex: hex) == nil)
  }

  @Test(arguments: [
    "#GGGGGG",   // not hex digits at all
    "#11111Z",   // one bad digit in an otherwise six-digit string
    "not a color",
    "#11 111",   // whitespace inside the digits
  ])
  func malformedInputIsRejected(_ hex: String) {
    #expect(HexColor.color(fromHex: hex) == nil)
  }

  // MARK: - Formatting

  @Test func opaqueColorFormatsAsSixDigits() {
    let color = Color(red: 17.0 / 255, green: 34.0 / 255, blue: 51.0 / 255, opacity: 1)
    #expect(HexColor.hex(from: color) == "#112233")
  }

  /// The inverse of `eightDigitReadsAlphaFirst`: the formatter has to put
  /// alpha first too, or round-tripping a parsed colour changes what it
  /// means. A `#RRGGBBAA`-ordered formatter would produce `"#FF000080"`
  /// here instead.
  @Test func translucentColorFormatsAlphaFirst() {
    let color = Color(red: 1, green: 0, blue: 0, opacity: 0.5)
    #expect(HexColor.hex(from: color) == "#80FF0000")
  }

  /// A colour picker can produce components outside 0...1 (Display P3 goes
  /// wider than sRGB); the formatter has to clamp rather than let a
  /// negative or >255 value corrupt the hex digits.
  @Test func outOfRangeComponentsAreClamped() {
    let color = Color(red: 1.5, green: -0.4, blue: 0.5019, opacity: 1.2)
    #expect(HexColor.hex(from: color) == "#FF0080")
  }

  // MARK: - Round trips

  @Test func sixDigitRoundTrips() throws {
    let original = "#A1B2C3"
    let color = try #require(HexColor.color(fromHex: original))
    #expect(HexColor.hex(from: color) == original)
  }

  @Test func eightDigitRoundTrips() throws {
    let original = "#80A1B2C3"
    let color = try #require(HexColor.color(fromHex: original))
    #expect(HexColor.hex(from: color) == original)
  }

  // MARK: - Helpers

  private func componentsMatch(
    _ resolved: Color.Resolved, red: Int, green: Int, blue: Int, tolerance: Double = 0.01)
    -> Bool
  {
    abs(Double(resolved.red) - Double(red) / 255.0) < tolerance
      && abs(Double(resolved.green) - Double(green) / 255.0) < tolerance
      && abs(Double(resolved.blue) - Double(blue) / 255.0) < tolerance
  }
}
