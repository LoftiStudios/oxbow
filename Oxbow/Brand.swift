import AppKit
import SwiftUI

/// A banner gradient and its contrasting foreground, kept together for contrast checks.
nonisolated struct BannerPalette: Equatable {
  let start: Color
  let end: Color
  let foreground: Color
}

/// Brand colours mirror the website's styles.css accent ramp unless noted otherwise.
nonisolated enum Brand {
  /// `--color-accent`.
  static let accent = Color(hex: 0x9184D9)

  /// White on accent-900 → accent-700. Accent-600 falls below 4.5:1 contrast for normal text.
  static let updateBannerDark = BannerPalette(
    start: Color(hex: 0x2B2741),
    end: Color(hex: 0x5D5294),
    foreground: .white)

  /// Accent-200 → accent-400 with accent-900 text. Reverse the dark gradient's direction to put
  /// the saturated end behind the trailing text in both appearances.
  static let updateBannerLight = BannerPalette(
    start: Color(hex: 0xE7E5FE),
    end: Color(hex: 0xB5ABFC),
    foreground: Color(hex: 0x2B2741))

  static func updateBanner(for scheme: ColorScheme) -> BannerPalette {
    scheme == .dark ? updateBannerDark : updateBannerLight
  }

  // MARK: - Progress

  /// Muted progress colour, independent of the website ramp.
  static let progressLight = Color(hex: 0x62658E)

  /// Lighter than the light-mode fill to contrast with dark window backgrounds.
  static let progressDark = Color(hex: 0x7A7DA3)

  static func progressFill(for scheme: ColorScheme) -> Color {
    scheme == .dark ? progressDark : progressLight
  }

  /// Dock fill is tuned against its near-white track, independent of the icon appearance.
  /// AppKit draws this bar, so use NSColor.
  static let dockProgress = NSColor(srgbRed: 0.231, green: 0.247, blue: 0.451, alpha: 1)
}

nonisolated extension Color {
  /// Hex RGB initializer for matching stylesheet colours.
  init(hex: UInt32) {
    self.init(
      .sRGB,
      red: Double((hex >> 16) & 0xFF) / 255,
      green: Double((hex >> 8) & 0xFF) / 255,
      blue: Double(hex & 0xFF) / 255)
  }
}
