import Testing

@testable import OxbowKit

@Suite("Chat colour")
struct ChatColorTests {

  /// Measured from the CLI's own SkiaSharp 2.88.9: input, the plain HSL round trip, and the
  /// readable colour against Oxbow's #111111 background.
  private static let measured: [(input: UInt32, roundTrip: UInt32, readable: UInt32)] = [
    (0xFF0000, 0xFF0000, 0xF20C0C), (0x0000FF, 0x0000FF, 0x0C49F2), (0x00FF00, 0x00FF00, 0x0CF20C),
    (0xB22222, 0xB12122, 0xB12122), (0xFF7F50, 0xFF7E4F, 0xF68358), (0x9ACD32, 0x99CD31, 0x99CD31),
    (0xFF4500, 0xFF4500, 0xF24A0C), (0x2E8B57, 0x2D8B57, 0x32995F), (0xDAA520, 0xDAA41F, 0xDAA41F),
    (0xD2691E, 0xD2681D, 0xD2681D), (0x5F9EA0, 0x5E9DA0, 0x5E9DA0), (0x1E90FF, 0x1D8FFF, 0x298FF3),
    (0xFF69B4, 0xFF68B3, 0xF770B3), (0x8A2BE2, 0x892AE2, 0x892AE2), (0x00FF7F, 0x00FF7E, 0x0CF27F),
    (0x9146FF, 0x9145FF, 0x924FF5), (0xFFFFFF, 0xFFFFFF, 0xFFFFFF), (0x000000, 0x000000, 0x666666),
    (0x123456, 0x113356, 0x2365A8),
  ]

  private static func hex(_ color: ChatColor) -> String {
    String(format: "%02X%02X%02X", color.red, color.green, color.blue)
  }

  @Test(arguments: measured.map(\.input))
  func roundTripsThroughHSLAsSkiaDoes(input: UInt32) throws {
    let expected = try #require(Self.measured.first { $0.input == input }).roundTrip
    let (hue, saturation, lightness) = ChatColor(rgb: input).hsl
    let rebuilt = ChatColor(hue: hue, saturation: saturation, lightness: lightness)
    #expect(Self.hex(rebuilt) == Self.hex(ChatColor(rgb: expected)))
  }

  @Test(arguments: measured.map(\.input))
  func makesAUsernameReadableAsTheCLIDoes(input: UInt32) throws {
    let expected = try #require(Self.measured.first { $0.input == input }).readable
    let readable = ChatColor(rgb: input).readable(against: ChatColor(rgb: 0x111111))
    #expect(Self.hex(readable) == Self.hex(ChatColor(rgb: expected)))
  }

  @Test func parsesSixAndEightDigitHex() throws {
    #expect(ChatColor(hex: "#1E90FF") == ChatColor(rgb: 0x1E90FF))
    // Skia reads eight digits as AARRGGBB.
    #expect(ChatColor(hex: "#80FF0000") == ChatColor(rgb: 0xFF0000, alpha: 0x80))
    #expect(ChatColor(hex: "#12345") == nil)
    #expect(ChatColor(hex: "not a colour") == nil)
  }
}
