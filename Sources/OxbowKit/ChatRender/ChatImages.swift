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

  /// CR:650-662. The instant a frame ends still shows that frame, not the next: the CLI's test is
  /// `<= 0`, and at 30 fps a boundary lands on a tick every third frame.
  func frameIndex(atMilliseconds milliseconds: Int64) -> Int {
    guard isAnimated, !durations.isEmpty else { return 0 }
    let cycle = Int64(durations.reduce(0, +) * 10)
    guard cycle > 0 else { return 0 }
    var remaining = milliseconds % cycle
    for (index, duration) in durations.enumerated() {
      remaining -= Int64(duration * 10)
      if remaining <= 0 { return index }
    }
    return durations.count - 1
  }
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
    case cheermote(String, Int)
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

  /// CR:1520-1551 and CE:12-23. `Cheer100` is a cheermote when everything before its first digit
  /// is exactly an embedded prefix and everything after parses as a 32-bit integer; the image is
  /// the highest tier at or below the amount, or the lowest tier for anything under it — so
  /// `Cheer0` and `Cheer007` show tier 1, as in the CLI. Tiers are sorted here, where the CLI
  /// trusts the file's order; the downloader writes them ascending, so nothing changes for real
  /// files. Every tier is scaled by the first tier's image scale, as the CLI does.
  func cheermote(_ word: String) -> ChatImage? {
    guard let digit = word.firstIndex(where: { $0.isASCII && $0.isNumber }), digit > word.startIndex,
          let amount = Int32(word[digit...]), word[digit...].allSatisfy({ $0.isASCII && $0.isNumber }),
          let tiers = embedded.cheermotes[String(word[..<digit])], !tiers.isEmpty
    else { return nil }
    let prefix = String(word[..<digit])
    let ordered = tiers.keys.sorted()
    let cost = ordered.last { $0 <= Int(amount) } ?? ordered[0]
    let firstScale = tiers[ordered[0]]?.scale ?? 2
    return cached(.cheermote(prefix, cost)) {
      guard var entry = tiers[cost] else { return nil }
      entry.scale = firstScale
      return emote(entry)
    }
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
    // Frames are independent: a 7TV emote can have well over a hundred.
    let results = Mutex([CGImage?](repeating: nil, count: frames.count))
    DispatchQueue.concurrentPerform(iterations: frames.count) { index in
      let image = Self.resample(frames[index], width: width, height: height)
      results.withLock { $0[index] = image }
    }
    let scaled = results.withLock { $0.compactMap { $0 } }
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

    // Where each output column and row samples, worked out once rather than per pixel.
    func taps(_ count: Int, from sourceCount: Int) -> [(near: Int, far: Int, weight: Double)] {
      let step = Double(sourceCount) / Double(count)
      return (0..<count).map { index in
        let position = (Double(index) + 0.5) * step - 0.5
        let near = min(max(Int(position.rounded(.down)), 0), sourceCount - 1)
        return (near, min(near + 1, sourceCount - 1), min(max(position - Double(near), 0), 1))
      }
    }
    let columns = taps(width, from: image.width)
    let rows = taps(height, from: image.height)
    let sourceRow = image.width * 4

    var output = [UInt8](repeating: 0, count: width * height * 4)
    source.withUnsafeBufferPointer { input in
      output.withUnsafeMutableBufferPointer { out in
        var o = 0
        for row in rows {
          let upper = row.near * sourceRow
          let lower = row.far * sourceRow
          let fy = row.weight
          for column in columns {
            let left = column.near * 4
            let right = column.far * 4
            let fx = column.weight
            for channel in 0..<4 {
              let top = Double(input[upper + left + channel]) * (1 - fx) + Double(input[upper + right + channel]) * fx
              let bottom = Double(input[lower + left + channel]) * (1 - fx) + Double(input[lower + right + channel]) * fx
              out[o + channel] = UInt8((top * (1 - fy) + bottom * fy).rounded())
            }
            o += 4
          }
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
