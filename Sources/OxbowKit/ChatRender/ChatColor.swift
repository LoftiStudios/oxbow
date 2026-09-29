import CoreGraphics
import Foundation

/// An 8-bit colour, as Skia holds one. Kept in bytes rather than `CGColor` because the CLI's
/// colour adjustment truncates to bytes on the way back, and matching it means doing the same.
struct ChatColor: Sendable, Equatable {
  var red: UInt8
  var green: UInt8
  var blue: UInt8
  var alpha: UInt8 = 255

  init(red: UInt8, green: UInt8, blue: UInt8, alpha: UInt8 = 255) {
    self.red = red
    self.green = green
    self.blue = blue
    self.alpha = alpha
  }

  init(rgb: UInt32, alpha: UInt8 = 255) {
    self.init(
      red: UInt8((rgb >> 16) & 0xFF), green: UInt8((rgb >> 8) & 0xFF), blue: UInt8(rgb & 0xFF),
      alpha: alpha)
  }

  /// `#RRGGBB`, or `#AARRGGBB` as Skia reads eight digits.
  init?(hex text: String) {
    let digits = text.hasPrefix("#") ? text.dropFirst() : Substring(text)
    guard let value = UInt32(digits, radix: 16) else { return nil }
    switch digits.count {
    case 6: self.init(rgb: value)
    case 8: self.init(rgb: value & 0xFF_FFFF, alpha: UInt8(value >> 24))
    default: return nil
    }
  }

  static let black = ChatColor(rgb: 0x000000)

  var cgColor: CGColor {
    CGColor(
      srgbRed: Double(red) / 255, green: Double(green) / 255, blue: Double(blue) / 255,
      alpha: Double(alpha) / 255)
  }

  /// WCAG relative luminance, on `byte / 255f` as SkiaSharp's extension computes it.
  var relativeLuminance: Float {
    func linear(_ channel: UInt8) -> Float {
      let v = Float(channel) / 255
      return v <= 0.04045 ? v / 12.92 : powf((v + 0.055) / 1.055, 2.4)
    }
    return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
  }

  // MARK: - HSL, as SkiaSharp 2.88 converts it

  /// Hue 0–360, saturation and lightness 0–100, in `Float` as SkiaSharp keeps them.
  var hsl: (hue: Float, saturation: Float, lightness: Float) {
    let r = Float(red) / 255
    let g = Float(green) / 255
    let b = Float(blue) / 255
    let high = max(r, g, b)
    let low = min(r, g, b)
    let delta = high - low
    let lightness = (high + low) / 2

    guard delta > .ulpOfOne else { return (0, 0, lightness * 100) }

    let saturation = lightness < 0.5 ? delta / (high + low) : delta / (2 - high - low)
    let dR = ((high - r) / 6 + delta / 2) / delta
    let dG = ((high - g) / 6 + delta / 2) / delta
    let dB = ((high - b) / 6 + delta / 2) / delta
    var hue: Float =
      if r == high { dB - dG } else if g == high { 1 / 3 + dR - dB } else { 2 / 3 + dG - dR }
    if hue < 0 { hue += 1 }
    if hue > 1 { hue -= 1 }
    return (hue * 360, saturation * 100, lightness * 100)
  }

  /// Rebuilds from HSL, truncating each channel as SkiaSharp's `(byte)(c * 255f)` does — which
  /// is why a round trip can lose one from a channel.
  init(hue: Float, saturation: Float, lightness: Float, alpha: UInt8 = 255) {
    let h = hue / 360
    let s = saturation / 100
    let l = lightness / 100
    var r = l
    var g = l
    var b = l
    if s != 0 {
      let v2 = l < 0.5 ? l * (1 + s) : (l + s) - (s * l)
      let v1 = 2 * l - v2
      r = Self.channel(v1, v2, h + 1 / 3)
      g = Self.channel(v1, v2, h)
      b = Self.channel(v1, v2, h - 1 / 3)
    }
    self.init(
      red: UInt8(clamping: Int(r * 255)), green: UInt8(clamping: Int(g * 255)),
      blue: UInt8(clamping: Int(b * 255)), alpha: alpha)
  }

  private static func channel(_ v1: Float, _ v2: Float, _ hue: Float) -> Float {
    var h = hue
    if h < 0 { h += 1 }
    if h > 1 { h -= 1 }
    if 6 * h < 1 { return v1 + (v2 - v1) * 6 * h }
    if 2 * h < 1 { return v2 }
    if 3 * h < 2 { return v1 + (v2 - v1) * (2 / 3 - h) * 6 }
    return v1
  }

  // MARK: - Readable usernames

  /// The CLI's `--readable-colors`, on by default: lightness pulled away from the background,
  /// awkward hues nudged, saturation capped at 90 (CR:1780-1859).
  func readable(against background: ChatColor) -> ChatColor {
    let (backgroundHue, backgroundSaturation, _) = background.hsl
    var (hue, saturation, lightness) = hsl

    if background.relativeLuminance > 0.5 {
      lightness = min(lightness, 60)
      if backgroundSaturation <= 28 {
        if hue > 48, hue < 90 { hue = Self.clamp(hue, 48, 90) }
        else if hue > 164, hue < 186 { hue = Self.clamp(hue, 164, 186) }
      }
    } else {
      lightness = max(lightness, 40)
      // `< 263` against a clamp to 264 is the CLI's own; kept.
      if backgroundSaturation <= 28, hue > 224, hue < 263 { hue = Self.clamp(hue, 224, 264) }
    }

    if backgroundSaturation > 28, saturation > 28 {
      let width: Float = 360
      let threshold: Float = 35
      let lower = hue - (backgroundHue > width / 2 ? backgroundHue - width : backgroundHue)
      let upper = hue - (backgroundHue > width / 2 ? backgroundHue : backgroundHue + width)
      let difference: Float? =
        if abs(lower) <= threshold { lower } else if abs(upper) <= threshold { upper } else { nil }
      if let difference {
        hue = backgroundHue + threshold * (difference < 0 ? -1 : 1)
        if hue < 0 { hue += width }
        hue = hue.truncatingRemainder(dividingBy: width)
      }
    }

    return ChatColor(hue: hue, saturation: min(saturation, 90), lightness: lightness, alpha: alpha)
  }

  private static func clamp(_ hue: Float, _ lower: Float, _ upper: Float) -> Float {
    hue >= (upper + lower) / 2 ? upper : lower
  }
}
