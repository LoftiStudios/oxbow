import SwiftUI

/// One appearance's worth of the update banner: the two ends of its gradient
/// and the text that sits on them.
///
/// The foreground travels with the gradient rather than being chosen at the
/// use site, because the two are only correct together — `BrandTests` checks
/// each palette's own foreground against its own two ends, which is only
/// possible if they arrive as one value.
nonisolated struct BannerPalette: Equatable {
  let start: Color
  let end: Color
  let foreground: Color
}

/// Oxbow's own colours, as opposed to the system ones the rest of the app is
/// built from.
///
/// The values mirror the custom properties in the website's `styles.css`
/// (`--color-accent` and the 100–900 ramp under it) so the app and
/// getoxbow.app cannot drift into two different purples. Deliberately small:
/// the app is a Mac app first, and everything that can be a system colour
/// still is one.
nonisolated enum Brand {
  /// `--color-accent`.
  static let accent = Color(hex: 0x9184D9)

  /// `--color-accent-900` → `--color-accent-700`, white on top.
  ///
  /// The ramp stops at 700 rather than continuing to the brighter 600
  /// (`#796CBF`) because white on 600 measures 4.4:1, just under WCAG AA's
  /// 4.5:1 floor for normal text.
  static let updateBannerDark = BannerPalette(
    start: Color(hex: 0x2B2741),
    end: Color(hex: 0x5D5294),
    foreground: .white)

  /// `--color-accent-200` → `--color-accent-400`, with `--color-accent-900`
  /// on top — the same band inverted rather than a different idea.
  ///
  /// The dark palette reused on a white window reads as a foreign object
  /// dropped onto the app rather than part of it. Light mode wants the
  /// opposite weight: a pale tint carrying dark text.
  ///
  /// **This one runs pale → deep, the reverse of the dark palette**, so that
  /// the trailing-aligned text sits on the more saturated end in both
  /// appearances. The colour pools behind the message either way instead of
  /// draining away from it in one of them, and the two contrast ratios land
  /// within 0.2 of each other (6.9:1 here, 6.7:1 dark) rather than 9.5 and
  /// 6.7. `theTwoBandsRunInOppositeDirections` pins the direction, because
  /// making the two palettes "consistent" is exactly the tidy-up that would
  /// undo it.
  ///
  /// The text is 900 rather than black, so it is literally the dark palette's
  /// gradient start — the two appearances are visibly the same family, and
  /// pure black on a lavender tint reads harsher than the app's own darkest
  /// value.
  static let updateBannerLight = BannerPalette(
    start: Color(hex: 0xE7E5FE),
    end: Color(hex: 0xB5ABFC),
    foreground: Color(hex: 0x2B2741))

  static func updateBanner(for scheme: ColorScheme) -> BannerPalette {
    scheme == .dark ? updateBannerDark : updateBannerLight
  }
}

nonisolated extension Color {
  /// `Color(hex: 0x9184D9)`, so the palette above can be read against the
  /// stylesheet it came from without translating every channel by hand.
  init(hex: UInt32) {
    self.init(
      .sRGB,
      red: Double((hex >> 16) & 0xFF) / 255,
      green: Double((hex >> 8) & 0xFF) / 255,
      blue: Double(hex & 0xFF) / 255)
  }
}
