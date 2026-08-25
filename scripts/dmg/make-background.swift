#!/usr/bin/env swift
//
//  make-background.swift — renders the Oxbow DMG window background.
//
//  Emits background@1x.png (640×400) and background@2x.png (1280×800) next to
//  this file, drawn from one set of layout constants so the two resolutions
//  cannot drift. `package-dmg.sh` combines them into the multi-resolution
//  background.tiff that dmgbuild actually consumes.
//
//  The icon coordinates below are the same numbers as `icon_locations` in
//  settings.py. They are declared here, printed on every run, and must stay in
//  lockstep — the artwork has no arrow object, only painted artwork that the
//  real Finder icons are positioned on top of.
//
//  Usage:  swift scripts/dmg/make-background.swift [--variant light|balanced]
//

import AppKit
import CoreGraphics
import UniformTypeIdentifiers

// MARK: - Canvas

let W: CGFloat = 640
let H: CGFloat = 400

/// Converts a top-left origin y (how Finder and the layout below think) into
/// the bottom-left origin y that Core Graphics draws in.
func Y(_ top: CGFloat) -> CGFloat { H - top }

// MARK: - Layout
//
// Single source of truth for both the artwork and settings.py.

let iconSize: CGFloat = 96

let cardRect = CGRect(x: 72, y: 28, width: 496, height: 344)   // top-left coords
let cardRadius: CGFloat = 16

let titleX: CGFloat = 124        // aligns with the app icon's left edge
let titleTop: CGFloat = 74
let taglineTop: CGFloat = 122

let rowY: CGFloat = 196          // centre line of the app / Applications row
let appX: CGFloat = 172
let applicationsX: CGFloat = 468
let licensesX: CGFloat = 320
let licensesY: CGFloat = 296

let arrowCenter = CGPoint(x: 320, y: rowY)

// MARK: - Palette

struct Palette {
    let name: String
    /// Appended to the emitted filenames. The default variant takes the plain
    /// `background.tiff` name, because that is what package-dmg.sh consumes
    /// when BACKGROUND is unset.
    let fileSuffix: String
    let backgroundStops: [(NSColor, CGFloat)]
    let card: NSColor
    let cardShadow: NSColor
    let title: NSColor
    let tagline: NSColor
    let arrow: NSColor
    let arrowShade: NSColor
}

func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: alpha)
}

/// Faithful to the original mockup: white card on a light mauve wash. Looks
/// better in a screenshot; loses its Finder labels in dark mode.
let lightPalette = Palette(
    name: "light",
    fileSuffix: "-light",
    backgroundStops: [(rgb(0xF4E8F3), 0.0), (rgb(0xDCC2E0), 0.45), (rgb(0xB98FC0), 1.0)],
    card: rgb(0xFFFFFF),
    cardShadow: rgb(0x2A1F35, 0.13),
    title: rgb(0x1D1729),
    tagline: rgb(0x6B6478),
    arrow: rgb(0xEBC128),
    arrowShade: rgb(0xDCAE14)
)

/// The default. Mid-tone card (L≈0.19) so Finder's icon labels stay legible in
/// BOTH light and dark mode. Finder draws those labels white in dark mode and
/// does not consult the background, so the light variant loses them entirely
/// on a white card. Same layout, darker skin.
let balancedPalette = Palette(
    name: "balanced",
    fileSuffix: "",
    backgroundStops: [(rgb(0x2E2447), 0.0), (rgb(0x453257), 0.5), (rgb(0x624468), 1.0)],
    card: rgb(0x8A6E96),
    cardShadow: rgb(0x0A0714, 0.35),
    title: rgb(0xFFFFFF),
    tagline: rgb(0xE4D8E8),
    arrow: rgb(0xF2CE45),
    arrowShade: rgb(0xE0B01A)
)

// MARK: - Drawing

func drawBackground(_ p: Palette) {
    let colors = p.backgroundStops.map { $0.0.cgColor } as CFArray
    let locations = p.backgroundStops.map { $0.1 }
    guard let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                    colors: colors, locations: locations),
          let ctx = NSGraphicsContext.current?.cgContext else { return }
    ctx.saveGState()
    ctx.clip(to: CGRect(x: 0, y: 0, width: W, height: H))
    ctx.drawLinearGradient(gradient,
                           start: CGPoint(x: 0, y: H),
                           end: CGPoint(x: W, y: 0),
                           options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    ctx.restoreGState()
}

func drawCard(_ p: Palette) {
    guard let ctx = NSGraphicsContext.current?.cgContext else { return }
    let rect = CGRect(x: cardRect.minX, y: Y(cardRect.maxY),
                      width: cardRect.width, height: cardRect.height)
    let path = CGPath(roundedRect: rect, cornerWidth: cardRadius,
                      cornerHeight: cardRadius, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -3), blur: 14, color: p.cardShadow.cgColor)
    ctx.addPath(path)
    ctx.setFillColor(p.card.cgColor)
    ctx.fillPath()
    ctx.restoreGState()
}

/// Draws `text` with its layout box's left edge at `x` and top at `topY`.
func drawText(_ text: String, font: NSFont, color: NSColor,
              kern: CGFloat, x: CGFloat, topY: CGFloat) {
    let attributed = NSAttributedString(string: text, attributes: [
        .font: font,
        .foregroundColor: color,
        .kern: kern,
    ])
    let size = attributed.size()
    attributed.draw(at: CGPoint(x: x, y: Y(topY) - size.height))
}

/// A chunky right-pointing block arrow. Filled and stroked with the same
/// colour and a round line join, which rounds the outer corners for free.
func drawArrow(_ p: Palette) {
    guard let ctx = NSGraphicsContext.current?.cgContext else { return }

    let width: CGFloat = 54
    let shaft: CGFloat = 18
    let headHeight: CGFloat = 40
    let headWidth: CGFloat = 26
    let cx = arrowCenter.x
    let cy = Y(arrowCenter.y)

    let points = [
        CGPoint(x: cx - width / 2,             y: cy - shaft / 2),
        CGPoint(x: cx + width / 2 - headWidth, y: cy - shaft / 2),
        CGPoint(x: cx + width / 2 - headWidth, y: cy - headHeight / 2),
        CGPoint(x: cx + width / 2,             y: cy),
        CGPoint(x: cx + width / 2 - headWidth, y: cy + headHeight / 2),
        CGPoint(x: cx + width / 2 - headWidth, y: cy + shaft / 2),
        CGPoint(x: cx - width / 2,             y: cy + shaft / 2),
    ]

    let path = CGMutablePath()
    path.addLines(between: points)
    path.closeSubpath()

    let gradientColors = [p.arrow.cgColor, p.arrowShade.cgColor] as CFArray
    guard let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                    colors: gradientColors, locations: [0, 1]) else { return }

    ctx.saveGState()
    ctx.setLineWidth(5)
    ctx.setLineJoin(.round)
    ctx.setStrokeColor(p.arrow.cgColor)
    ctx.addPath(path)
    ctx.strokePath()

    ctx.addPath(path)
    ctx.clip()
    ctx.drawLinearGradient(gradient,
                           start: CGPoint(x: cx, y: cy + headHeight / 2),
                           end: CGPoint(x: cx, y: cy - headHeight / 2),
                           options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    ctx.restoreGState()
}

func render(_ p: Palette, scale: CGFloat) -> CGImage {
    let pixelsWide = Int(W * scale)
    let pixelsHigh = Int(H * scale)
    guard let space = CGColorSpace(name: CGColorSpace.sRGB),
          let ctx = CGContext(data: nil, width: pixelsWide, height: pixelsHigh,
                              bitsPerComponent: 8, bytesPerRow: 0, space: space,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
        fatalError("could not create a \(pixelsWide)×\(pixelsHigh) context")
    }
    ctx.scaleBy(x: scale, y: scale)

    let previous = NSGraphicsContext.current
    NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
    defer { NSGraphicsContext.current = previous }

    drawBackground(p)
    drawCard(p)
    drawText("Oxbow",
             font: .systemFont(ofSize: 42, weight: .ultraLight),
             color: p.title, kern: 0.6, x: titleX, topY: titleTop)
    drawText("Twitch VODs, saved properly.",
             font: .systemFont(ofSize: 15, weight: .regular),
             color: p.tagline, kern: 0.1, x: titleX, topY: taglineTop)
    drawArrow(p)

    guard let image = ctx.makeImage() else { fatalError("could not snapshot the context") }
    return image
}

func writePNG(_ image: CGImage, to url: URL) {
    guard let destination = CGImageDestinationCreateWithURL(
        url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
        fatalError("could not open \(url.path) for writing")
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else {
        fatalError("could not write \(url.path)")
    }
}

// MARK: - Entry point

let variantName = CommandLine.arguments.firstIndex(of: "--variant")
    .flatMap { CommandLine.arguments.indices.contains($0 + 1) ? CommandLine.arguments[$0 + 1] : nil }
    ?? "balanced"

let palette: Palette
switch variantName {
case "light":    palette = lightPalette
case "balanced": palette = balancedPalette
default:
    FileHandle.standardError.write("unknown variant '\(variantName)' (light | balanced)\n".data(using: .utf8)!)
    exit(2)
}

let outputDirectory = URL(fileURLWithPath: CommandLine.arguments[0])
    .deletingLastPathComponent()

let suffix = palette.fileSuffix
var pngNames: [String] = []
for scale in [CGFloat(1), CGFloat(2)] {
    let name = "background\(suffix)@\(Int(scale))x.png"
    let url = outputDirectory.appendingPathComponent(name)
    writePNG(render(palette, scale: scale), to: url)
    pngNames.append(name)
    print("wrote \(name)  \(Int(W * scale))×\(Int(H * scale))")
}

// Finder needs ONE file carrying both resolutions, or the background is soft on
// every Retina display. tiffutil's multi-page TIFF is the only container Finder
// reads that way; a plain @2x PNG next to the @1x is ignored.
let tiffName = "background\(suffix).tiff"
let tiffutil = Process()
tiffutil.executableURL = URL(fileURLWithPath: "/usr/bin/tiffutil")
tiffutil.currentDirectoryURL = outputDirectory
tiffutil.arguments = ["-cathidpicheck"] + pngNames + ["-out", tiffName]
try tiffutil.run()
tiffutil.waitUntilExit()
guard tiffutil.terminationStatus == 0 else {
    FileHandle.standardError.write("tiffutil failed\n".data(using: .utf8)!)
    exit(1)
}
print("wrote \(tiffName)  (multi-resolution)")

print("""

window_rect  ((x, y), (\(Int(W)), \(Int(H))))
icon_size    \(Int(iconSize))
icon_locations
  Oxbow.app          (\(Int(appX)), \(Int(rowY)))
  Applications       (\(Int(applicationsX)), \(Int(rowY)))
  Licenses           (\(Int(licensesX)), \(Int(licensesY)))
""")
