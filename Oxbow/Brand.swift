import AppKit
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

  // MARK: - Progress

  /// What a progress bar fills with in light mode.
  ///
  /// The one place the app spends colour on something that is neither a status
  /// nor a banner. A progress bar is the longest-lived colour on screen — a
  /// six-hour VOD means six hours of it — which makes it the natural place to
  /// put the brand rather than the system accent, and the last place to want
  /// anything loud.
  ///
  /// Neither fill is a value from the website ramp, unlike everything above
  /// them: this one sits a shade above `--color-accent-2-700` (`#5C5783`) on
  /// the muted ramp, and both are cooler than anything on either ramp — green
  /// edges above red here, where every published value has red above green.
  /// They are a family with each other rather than with the stylesheet.
  static let progressLight = Color(hex: 0x62658E)

  /// What a progress bar fills with in dark mode.
  ///
  /// **Lighter than the light-mode fill, which is the whole point** and reads
  /// backwards at a glance. A bar is a solid shape on a background, not text:
  /// in light mode it has to be darker than a white window, and in dark mode
  /// lighter than a near-black one, so the two values move in the same
  /// direction as their backgrounds rather than opposite ones.
  /// `darkModeGetsTheLighterOfTheTwoFills` pins that, because "the dark
  /// appearance should get the darker colour" is exactly the tidy-up that
  /// would undo it.
  ///
  /// Lands beside `--color-accent-2-600` (`#7972A9`) in lightness, cooler in
  /// the same way its light-mode counterpart is.
  static let progressDark = Color(hex: 0x7A7DA3)

  /// The fill for an appearance.
  static func progressFill(for scheme: ColorScheme) -> Color {
    scheme == .dark ? progressDark : progressLight
  }

  /// What the dock tile's progress bar fills with.
  ///
  /// **Not `progressLight` or `progressDark`.** Those two are chosen against a
  /// window — one darker than white, one lighter than near-black — and the
  /// dock bar sits on neither. It sits on the app icon, whose appearance the
  /// user controls (Default, Dark, Clear, Tinted), so there is no background
  /// to tune a value against.
  ///
  /// This is the gold of the icon's own download arrow, sampled from the
  /// rendered tile rather than picked: mean `#D2BA54` over the arrow's pixels.
  /// The bar is then the same colour as the thing the icon already draws,
  /// which is the one relationship that holds in every appearance.
  ///
  /// `NSColor`, not `Color`: the dock tile is drawn with AppKit, and a
  /// `Color` would have to be converted at every fill.
  static let dockProgress = NSColor(srgbRed: 0.825, green: 0.729, blue: 0.329, alpha: 1)
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
