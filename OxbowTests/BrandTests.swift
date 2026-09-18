import AppKit
import SwiftUI
import Testing
@testable import Oxbow

@Suite("Brand palette")
struct BrandTests {

  /// Pin channel order in the hex initializer against the website accent.
  @Test func hexInitialiserReadsChannelsInRGBOrder() throws {
    let components = try #require(NSColor(Color(hex: 0x9184D9)).usingColorSpace(.sRGB))
    #expect(abs(components.redComponent - 0x91 / 255.0) < 0.001)
    #expect(abs(components.greenComponent - 0x84 / 255.0) < 0.001)
    #expect(abs(components.blueComponent - 0xD9 / 255.0) < 0.001)
  }

  /// Check every palette's foreground against both gradient endpoints at the 4.5:1
  /// text-contrast floor.
  @Test func everyPaletteKeepsItsForegroundAboveTheContrastFloor() throws {
    for palette in [Brand.updateBannerLight, Brand.updateBannerDark] {
      for end in [palette.start, palette.end] {
        #expect(try contrast(of: palette.foreground, on: end) >= 4.5)
      }
    }
  }

  /// Luminance detects accidentally swapped appearance palettes.
  @Test func lightModeGetsTheLighterOfTheTwoPalettes() throws {
    let light = Brand.updateBanner(for: .light)
    let dark = Brand.updateBanner(for: .dark)
    #expect(try luminance(of: light.start) > luminance(of: dark.start))
    #expect(try luminance(of: light.end) > luminance(of: dark.end))
    // And the text inverts with it, or the band would be light-on-light.
    #expect(try luminance(of: light.foreground) < luminance(of: dark.foreground))
  }

  /// Opposite gradient directions keep trailing-aligned text over the saturated end in both
  /// appearances.
  @Test func theTwoBandsRunInOppositeDirections() throws {
    #expect(try luminance(of: Brand.updateBannerDark.start)
      < luminance(of: Brand.updateBannerDark.end))
    #expect(try luminance(of: Brand.updateBannerLight.start)
      > luminance(of: Brand.updateBannerLight.end))
  }

  /// Non-text contrast floor is 3:1 against the window. This does not cover the
  /// environment-resolved track, which needs visual verification; measured track contrasts were
  /// 4.46:1 light and 3.09:1 dark.
  @Test func bothProgressFillsStayVisibleOnTheirOwnWindow() throws {
    #expect(try contrast(of: Brand.progressLight, on: .white) >= 3)
    #expect(try contrast(of: Brand.progressDark, on: Color(hex: 0x1F1F1F)) >= 3)
  }

  /// Progress fills get lighter in dark mode to separate from the window.
  @Test func darkModeGetsTheLighterOfTheTwoFills() throws {
    #expect(try luminance(of: Brand.progressDark) > luminance(of: Brand.progressLight))
  }

  /// Both appearances retain blue-dominant fills.
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
