#!/usr/bin/env swift
// Composes captured windows in placement order. Captures include native shadows when
// screencapture omits `-o`. Usage: `composite.swift --background bg.png --out hero.png --place
// queue.png:0:190:1.0 --place intake.png:1250:40:1.0`. Placements are PATH:X:Y:SCALE in
// background pixels with a top-left origin.

import AppKit
import CoreGraphics
import Foundation

struct Placement {
  let url: URL
  let x: CGFloat
  let y: CGFloat
  let scale: CGFloat
}

func die(_ message: String) -> Never {
  FileHandle.standardError.write(Data((message + "\n").utf8))
  exit(1)
}

var backgroundPath: String?
var outputPath: String?
var placements: [Placement] = []

var arguments = Array(CommandLine.arguments.dropFirst())
while let flag = arguments.first {
  arguments.removeFirst()
  switch flag {
  case "--background":
    guard let value = arguments.first else { die("--background needs a path") }
    arguments.removeFirst()
    backgroundPath = value
  case "--out":
    guard let value = arguments.first else { die("--out needs a path") }
    arguments.removeFirst()
    outputPath = value
  case "--place":
    guard let spec = arguments.first else { die("--place needs PATH:X:Y:SCALE") }
    arguments.removeFirst()
    // Split from the right to preserve colons in paths.
    let parts = spec.split(separator: ":")
    guard parts.count >= 4,
          let scale = Double(parts[parts.count - 1]),
          let y = Double(parts[parts.count - 2]),
          let x = Double(parts[parts.count - 3])
    else { die("bad placement \"\(spec)\" — expected PATH:X:Y:SCALE") }
    let path = parts[0..<(parts.count - 3)].joined(separator: ":")
    placements.append(Placement(
      url: URL(filePath: path), x: CGFloat(x), y: CGFloat(y), scale: CGFloat(scale)))
  default:
    die("unknown option \(flag)")
  }
}

guard let backgroundPath, let outputPath else {
  die("usage: composite.swift --background BG --out OUT --place PATH:X:Y:SCALE …")
}

func loadImage(_ url: URL) -> CGImage {
  guard
    let source = CGImageSourceCreateWithURL(url as CFURL, nil),
    let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
  else { die("could not read \(url.path)") }
  return image
}

let background = loadImage(URL(filePath: backgroundPath))
let width = background.width
let height = background.height

guard
  let context = CGContext(
    data: nil,
    width: width,
    height: height,
    bitsPerComponent: 8,
    bytesPerRow: 0,
    space: CGColorSpace(name: CGColorSpace.sRGB)!,
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
else { die("could not create a \(width)x\(height) context") }

// Convert top-left placement coordinates to Core Graphics' bottom-left origin.
context.interpolationQuality = .high
context.draw(background, in: CGRect(x: 0, y: 0, width: width, height: height))

for placement in placements {
  let image = loadImage(placement.url)
  let drawWidth = CGFloat(image.width) * placement.scale
  let drawHeight = CGFloat(image.height) * placement.scale
  let flippedY = CGFloat(height) - placement.y - drawHeight
  context.draw(image, in: CGRect(
    x: placement.x, y: flippedY, width: drawWidth, height: drawHeight))
  let name = placement.url.lastPathComponent
  print("  \(name)  at \(Int(placement.x)),\(Int(placement.y))  "
        + "\(Int(drawWidth))x\(Int(drawHeight))  scale \(placement.scale)")
}

guard
  let composed = context.makeImage(),
  let destination = CGImageDestinationCreateWithURL(
    URL(filePath: outputPath) as CFURL, "public.png" as CFString, 1, nil)
else { die("could not encode \(outputPath)") }

CGImageDestinationAddImage(destination, composed, nil)
guard CGImageDestinationFinalize(destination) else { die("could not write \(outputPath)") }
print("wrote \(outputPath)  \(width)x\(height)")
