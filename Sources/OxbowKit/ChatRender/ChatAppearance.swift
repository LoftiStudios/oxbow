import Foundation

/// The render options that change how a comment looks rather than where it goes, resolved
/// from a `RenderRequest` the way the CLI resolves its arguments.
struct ChatAppearance: Sendable {
  let background: ChatColor
  /// Drawn behind comments at odd positions in the file. Nil when alternate backgrounds are off,
  /// which leaves its colour inert, as it is in the CLI.
  let alternateBackground: ChatColor?
  let message: ChatColor
  let hasTimestamps: Bool
  let hasOutline: Bool
  /// Stroke width of the outline, scaled like every other spacing (CR:99).
  let outlineWidth: Double

  init(request: RenderRequest) {
    background = ChatColor(hex: request.backgroundColor) ?? ChatColor(rgb: 0x111111)
    alternateBackground = request.hasAlternateBackgrounds
      ? ChatColor(hex: request.alternateBackgroundColor) ?? ChatColor(rgb: 0x191919) : nil
    message = ChatColor(hex: request.messageColor) ?? ChatColor(rgb: 0xFFFFFF)
    hasTimestamps = request.hasTimestamps
    hasOutline = request.hasOutline
    outlineWidth = Double(request.outlineSize) * request.fontSize / 24
  }

  /// By position in the file, not on screen: the stripes stay put as chat scrolls (CR:826).
  func background(forComment index: Int) -> ChatColor {
    if let alternateBackground, index % 2 == 1 { alternateBackground } else { background }
  }

  /// The CLI's `--readable-colors`, on by default and not a `RenderRequest` field (CR:1764-1778).
  /// Against the outline when there is one, since that is what the name is read against;
  /// otherwise against this comment's own background.
  func username(_ color: ChatColor, forComment index: Int) -> ChatColor {
    if hasOutline { return color.readable(against: .black) }
    let behind = background(forComment: index)
    // A mostly transparent background says nothing about what the name will sit on.
    guard behind.alpha >= 127 else { return color }
    let readable = color.readable(against: behind)
    return behind.alpha == 255 ? readable : color.blended(toward: readable, by: Float(behind.alpha) / 255)
  }
}

/// A comment's time as the CLI writes it: `m:ss`, `h:mm:ss`, or total hours past a day
/// (CR:1924-1936). The VOD's own clock, not the file's.
struct Timestamp: Sendable, Equatable {
  let text: String
  /// Which of the CLI's four fixed widths it takes: `0:00`, `00:00`, `0:00:00`, `00:00:00`.
  let lengthClass: Int

  init(seconds: Int) {
    let hours = seconds / 3600
    let minutes = seconds / 60 % 60
    let secs = seconds % 60
    text = if seconds >= 3600 {
      String(format: hours >= 24 ? "%02d:%02d:%02d" : "%d:%02d:%02d", hours, minutes, secs)
    } else {
      String(format: "%d:%02d", minutes, secs)
    }
    lengthClass = switch seconds {
    case 36000...: 3
    case 3600...: 2
    case 600...: 1
    default: 0
    }
  }
}

extension ChatColor {
  /// SkiaSharp's `Lerp`, through float channels and back. [inferred] Skia rounds on the way back
  /// to bytes; unreachable while Oxbow's backgrounds are opaque.
  func blended(toward other: ChatColor, by factor: Float) -> ChatColor {
    func mix(_ a: UInt8, _ b: UInt8) -> UInt8 {
      UInt8(clamping: Int(((Float(a) + (Float(b) - Float(a)) * factor)).rounded()))
    }
    return ChatColor(
      red: mix(red, other.red), green: mix(green, other.green), blue: mix(blue, other.blue),
      alpha: mix(alpha, other.alpha))
  }
}
