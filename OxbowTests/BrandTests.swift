import AppKit
import SwiftUI
import Testing
@testable import Oxbow

@Suite("Brand palette")
struct BrandTests {

  /// The one thing that can silently go wrong in a hex initialiser is channel
  /// order, and a swapped red and blue still compiles, still renders, and
  /// still looks like a colour. `#9184d9` is the website's `--color-accent`.
  @Test func hexInitialiserReadsChannelsInRGBOrder() throws {
    let components = try #require(NSColor(Color(hex: 0x9184D9)).usingColorSpace(.sRGB))
    #expect(abs(components.redComponent - 0x91 / 255.0) < 0.001)
    #expect(abs(components.greenComponent - 0x84 / 255.0) < 0.001)
    #expect(abs(components.blueComponent - 0xD9 / 255.0) < 0.001)
  }

  /// Each palette carries its own foreground, so each is checked against its
  /// own two gradient ends rather than against a colour assumed to be white.
  /// WCAG AA for normal text is 4.5:1, and the banner's text is normal text.
  ///
  /// Written as a loop over both appearances deliberately: the light palette
  /// was added months after the dark one, and a floor that only ever covered
  /// the colours that existed when it was written is a floor that stops
  /// working the moment someone adds a third.
  @Test func everyPaletteKeepsItsForegroundAboveTheContrastFloor() throws {
    for palette in [Brand.updateBannerLight, Brand.updateBannerDark] {
      for end in [palette.start, palette.end] {
        #expect(try contrast(of: palette.foreground, on: end) >= 4.5)
      }
    }
  }

  /// Catches the two palettes being swapped — which compiles, renders, and is
  /// wrong in both appearances at once. Asserted by luminance rather than by
  /// identity so it describes what "light mode" has to mean, not merely which
  /// constant got returned.
  @Test func lightModeGetsTheLighterOfTheTwoPalettes() throws {
    let light = Brand.updateBanner(for: .light)
    let dark = Brand.updateBanner(for: .dark)
    #expect(try luminance(of: light.start) > luminance(of: dark.start))
    #expect(try luminance(of: light.end) > luminance(of: dark.end))
    // And the text inverts with it, or the band would be light-on-light.
    #expect(try luminance(of: light.foreground) < luminance(of: dark.foreground))
  }

  /// The two bands run in opposite directions, and that is the decision, not
  /// an oversight: dark mode deepens toward the leading edge, light mode
  /// toward the trailing one. What it buys is that the text — which is
  /// trailing-aligned in both — always sits on the *more saturated* end, so
  /// the colour pools behind the message either way rather than draining away
  /// from it in one appearance.
  @Test func theTwoBandsRunInOppositeDirections() throws {
    #expect(try luminance(of: Brand.updateBannerDark.start)
      < luminance(of: Brand.updateBannerDark.end))
    #expect(try luminance(of: Brand.updateBannerLight.start)
      > luminance(of: Brand.updateBannerLight.end))
  }

  /// A progress bar is a graphical object, so the floor is WCAG's 3:1 for
  /// non-text contrast rather than the 4.5:1 the banner's text answers to.
  ///
  /// Each fill is measured against the window its own appearance draws, since
  /// that is the surface it has to separate from. The tighter constraint is
  /// actually the bar's own track — a `.quaternary` grey the environment
  /// resolves, so it cannot be named as a constant here — and both fills were
  /// measured against it from a render before landing: 4.46:1 light, 3.09:1
  /// dark. An earlier dark value sat at 2.20:1 there while still clearing this
  /// test against the window, which is exactly why the number to watch is the
  /// track and why these two were chosen over it.
  @Test func bothProgressFillsStayVisibleOnTheirOwnWindow() throws {
    #expect(try contrast(of: Brand.progressLight, on: .white) >= 3)
    #expect(try contrast(of: Brand.progressDark, on: Color(hex: 0x1F1F1F)) >= 3)
  }

  /// The fills invert relative to the banner palettes above, and that is the
  /// decision rather than an oversight. A banner carries text, so its dark
  /// appearance takes the *darker* band; a progress bar is a solid shape on a
  /// background, so its dark appearance takes the *lighter* fill — otherwise
  /// the bar disappears into the window it sits on.
  @Test func darkModeGetsTheLighterOfTheTwoFills() throws {
    #expect(try luminance(of: Brand.progressDark) > luminance(of: Brand.progressLight))
  }

  /// Both fills stay in the same family, which is what stops the two
  /// appearances reading as two different products. Blue is the dominant
  /// channel in each, and by a similar margin.
  @Test func bothFillsStayInTheSameFamily() throws {
    for fill in [Brand.progressLight, Brand.progressDark] {
      let components = try #require(NSColor(fill).usingColorSpace(.sRGB))
      #expect(components.blueComponent > components.redComponent)
      #expect(components.blueComponent > components.greenComponent)
    }
  }

  // MARK: - WCAG 2.1 relative luminance

  private func contrast(of foreground: Color, on background: Color) throws -> Double {
    let (lighter, darker) = try (
      max(luminance(of: foreground), luminance(of: background)),
      min(luminance(of: foreground), luminance(of: background)))
    return (lighter + 0.05) / (darker + 0.05)
  }

  private func luminance(of color: Color) throws -> Double {
    let components = try #require(NSColor(color).usingColorSpace(.sRGB))
    let channels = [
      components.redComponent, components.greenComponent, components.blueComponent,
    ].map { channel -> Double in
      channel <= 0.04045 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4)
    }
    return 0.2126 * channels[0] + 0.7152 * channels[1] + 0.0722 * channels[2]
  }
}
