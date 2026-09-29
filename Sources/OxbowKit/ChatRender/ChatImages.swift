import CoreGraphics
import Foundation
import ImageIO
import Synchronization

/// A badge or emote, decoded and scaled once to the size the CLI draws it.
final class ChatImage: Sendable {
  /// Every frame fully composited, as Skia's codec produces them; one for a still image.
  let frames: [CGImage]
  /// Per frame, in hundredths of a second after the CLI's rules (TE:62-95). Empty when still.
  let durations: [Int]
  let width: Int
  let height: Int

  init(frames: [CGImage], durations: [Int]) {
    self.frames = frames
    self.durations = durations
    width = frames.first?.width ?? 0
    height = frames.first?.height ?? 0
  }

  var isAnimated: Bool { frames.count > 1 }
}

/// The badges and emotes a chat file embeds, looked up the way the CLI looks them up, decoded
/// on first use and kept. docs/design/native-chat-render.md, phase 2.
final class ChatImages: Sendable {
  private let embedded: ChatDocument.EmbeddedImages
  private let scale: Double
  private let cache = Mutex<[Key: ChatImage?]>([:])

  private enum Key: Hashable {
    case badge(String, String)
    case firstParty(String)
    case thirdParty(String)
  }

  init(_ embedded: ChatDocument.EmbeddedImages, fontSize: Double) {
    self.embedded = embedded
    scale = fontSize / 24
  }

  /// No images at all: what a chat file downloaded without `-E` gives.
  static let none = ChatImages(ChatDocument.EmbeddedImages(), fontSize: 24)

  /// CR:1897-1919: by badge name, then version, exactly; a missing one is skipped.
  func badge(_ name: String, version: String) -> ChatImage? {
    cached(.badge(name, version)) {
      guard let data = embedded.badges[name]?[version], let source = Self.source(data),
            let first = CGImageSourceCreateImageAtIndex(source, 0, nil)
      else { return nil }
      return Self.still(first, height: badgeHeight(for: first))
    }
  }

  /// CR:1553-1585: by the fragment's emote id.
  func firstParty(_ id: String) -> ChatImage? {
    cached(.firstParty(id)) { embedded.firstParty[id].flatMap(emote) }
  }

  /// CR:1198-1202: by the word exactly as typed — case-sensitive, whole word.
  func thirdParty(_ name: String) -> (image: ChatImage, isZeroWidth: Bool)? {
    guard let entry = embedded.thirdParty[name] else { return nil }
    return cached(.thirdParty(name)) { emote(entry) }.map { ($0, entry.isZeroWidth) }
  }

  private func cached(_ key: Key, make: () -> ChatImage?) -> ChatImage? {
    if let hit = cache.withLock({ $0[key] }) { return hit }
    let made = make()
    cache.withLock { $0[key] = .some(made) }
    return made
  }

  // MARK: - Sizes, as the CLI computes them

  /// CR:2006-2013: 22 at font size 15, half rounded to even, snapped onto a multiple of the
  /// source height when within a pixel.
  private func badgeHeight(for image: CGImage) -> Int {
    let desired = Int((36 * scale).rounded(.toNearestOrEven))
    let snap = Int((1 * scale).rounded(.toNearestOrEven))
    return Self.snap(desired, within: snap, of: image.height)
  }

  /// CR:2018-2049: the image's own pixels normalised to 2×, then scaled with the font — 35 px for
  /// a standard 56 px Twitch emote at font size 15. The JSON's width and height are not used.
  private func emote(_ entry: ChatDocument.EmbeddedImage) -> ChatImage? {
    guard let source = Self.source(entry.data) else { return nil }
    let count = CGImageSourceGetCount(source)
    // Skia's PNG codec does not animate APNG; take the first frame of any PNG.
    let isPNG = (CGImageSourceGetType(source) as String?) == "public.png"
    let frameCount = isPNG ? 1 : max(count, 1)
    let frames = (0..<frameCount).compactMap { CGImageSourceCreateImageAtIndex(source, $0, nil) }
    guard let first = frames.first else { return nil }

    let factor = 2.0 / Double(max(entry.scale, 1)) * scale
    let height: Int
    if abs(factor - 1) < 0.01 {
      height = first.height
    } else {
      let snap = Int((4 * scale).rounded(.toNearestOrEven))
      height = Self.snap(Int(Double(first.height) * factor), within: snap, of: first.height)
    }
    let width = Int(Double(height) / Double(first.height) * Double(first.width))
    let scaled = frames.compactMap { Self.resample($0, width: width, height: height) }
    guard scaled.count == frames.count else { return nil }
    return ChatImage(
      frames: scaled, durations: scaled.count > 1 ? Self.durations(source, count: scaled.count) : [])
  }

  private static func still(_ image: CGImage, height: Int) -> ChatImage? {
    let width = Int(Double(height) / Double(image.height) * Double(image.width))
    return resample(image, width: width, height: height).map { ChatImage(frames: [$0], durations: []) }
  }

  /// TH:1526-1533, for the equal thresholds the CLI always passes: moves `desired` onto a
  /// multiple of the source height when it is within `threshold` of one.
  static func snap(_ desired: Int, within threshold: Int, of imageHeight: Int) -> Int {
    guard threshold != 0, imageHeight > 0 else { return desired }
    let over = (desired + threshold) % imageHeight
    return over <= threshold * 2 ? desired + threshold - over : desired
  }

  /// TE:62-95: each frame's delay in whole hundredths, truncated; a zero becomes 100 ms, and if
  /// every frame came out at zero or one hundredth, all of them do. ImageIO's unclamped delays
  /// agree with Skia's on every embedded file measured; the clamped ones do not.
  static func durations(_ source: CGImageSource, count: Int) -> [Int] {
    let raw = (0..<count).map { index -> Int in
      let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any]
      let seconds = [
        (kCGImagePropertyGIFDictionary, kCGImagePropertyGIFUnclampedDelayTime),
        (kCGImagePropertyWebPDictionary, kCGImagePropertyWebPUnclampedDelayTime),
        (kCGImagePropertyPNGDictionary, kCGImagePropertyAPNGUnclampedDelayTime),
      ].lazy.compactMap { dictionary, key in
        (properties?[dictionary] as? [CFString: Any])?[key] as? Double
      }.first ?? 0
      return Int((seconds * 1000).rounded()) / 10
    }
    return adjusted(raw)
  }

  static func adjusted(_ hundredths: [Int]) -> [Int] {
    let total = hundredths.reduce(0, +)
    if total == 0 || total == hundredths.count {
      return hundredths.map { _ in 10 }
    }
    return hundredths.map { $0 == 0 ? 10 : $0 }
  }

  private static func source(_ data: Data) -> CGImageSource? {
    CGImageSourceCreateWithData(data as CFData, nil)
  }

  // MARK: - Resampling

  /// Bilinear on premultiplied pixels, pixel centres aligned, edges clamped: what the CLI's
  /// `ScalePixels(…, High)` measures as at these ratios, to within 2 in a channel. No Core
  /// Graphics interpolation quality comes close (docs/design/native-chat-render.md, phase 2).
  static func resample(_ image: CGImage, width: Int, height: Int) -> CGImage? {
    guard width > 0, height > 0, let source = rgba(image) else { return nil }
    if width == image.width, height == image.height { return make(source, width: width, height: height) }

    let sourceWidth = image.width
    let sourceHeight = image.height
    var output = [UInt8](repeating: 0, count: width * height * 4)
    let xScale = Double(sourceWidth) / Double(width)
    let yScale = Double(sourceHeight) / Double(height)
    for y in 0..<height {
      let v = (Double(y) + 0.5) * yScale - 0.5
      let y0 = min(max(Int(v.rounded(.down)), 0), sourceHeight - 1)
      let y1 = min(y0 + 1, sourceHeight - 1)
      let fy = min(max(v - Double(y0), 0), 1)
      for x in 0..<width {
        let u = (Double(x) + 0.5) * xScale - 0.5
        let x0 = min(max(Int(u.rounded(.down)), 0), sourceWidth - 1)
        let x1 = min(x0 + 1, sourceWidth - 1)
        let fx = min(max(u - Double(x0), 0), 1)
        for channel in 0..<4 {
          func at(_ px: Int, _ py: Int) -> Double { Double(source[(py * sourceWidth + px) * 4 + channel]) }
          let top = at(x0, y0) * (1 - fx) + at(x1, y0) * fx
          let bottom = at(x0, y1) * (1 - fx) + at(x1, y1) * fx
          output[(y * width + x) * 4 + channel] = UInt8((top * (1 - fy) + bottom * fy).rounded())
        }
      }
    }
    return make(output, width: width, height: height)
  }

  private static let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
  private static let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue

  private static func rgba(_ image: CGImage) -> [UInt8]? {
    var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
    let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
      guard let context = CGContext(
        data: buffer.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8,
        bytesPerRow: image.width * 4, space: colorSpace, bitmapInfo: bitmapInfo)
      else { return false }
      context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
      return true
    }
    return drawn ? pixels : nil
  }

  private static func make(_ pixels: [UInt8], width: Int, height: Int) -> CGImage? {
    var copy = pixels
    return copy.withUnsafeMutableBytes { buffer in
      CGContext(
        data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
        bytesPerRow: width * 4, space: colorSpace, bitmapInfo: bitmapInfo)?.makeImage()
    }
  }
}
