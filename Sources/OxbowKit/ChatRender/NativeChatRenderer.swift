import CoreGraphics
// CTFont is immutable and documented thread-safe, but not yet annotated Sendable.
@preconcurrency import CoreText
import Foundation
import Synchronization

/// Draws the chat column natively, matching the CLI's render of the same file. Plain text only
/// so far: docs/design/native-chat-render.md §6, phase 1 slice 1.
///
/// Any frame can be drawn on its own. The CLI builds each redraw from the last, but what it
/// carries between them is a cache, not state: the newest visible comment fixes the whole frame
/// (see `ChatTimeline.newestIndex`), and comments stack upward from it.
public final class NativeChatRenderer: ChatFrameSource {
  public let size: CGSize

  private let document: ChatDocument
  private let timeline: ChatTimeline
  private let style: ChatTextStyle
  private let background: CGColor
  private let messageColor: CGColor
  /// Laid-out comments by index; nil where the CLI skips the comment. Layout is the expensive
  /// part of a frame and a comment appears in hundreds of them.
  private let layouts = Mutex<[Int: MessageLayout?]>([:])

  public init(document: ChatDocument, request: RenderRequest) {
    self.document = document
    size = CGSize(width: request.width, height: request.height)
    timeline = ChatTimeline(document: document, framerate: request.framerate)
    style = ChatTextStyle(width: request.width, height: request.height, fontSize: request.fontSize)
    background = HexColor.parse(request.backgroundColor) ?? HexColor.color(rgb: 0x111111)
    messageColor = HexColor.parse(request.messageColor) ?? HexColor.color(rgb: 0xFFFFFF)
  }

  public var duration: Duration { timeline.duration }

  public var frameCount: Int { timeline.frameCount }

  public func frame(at time: Duration) -> CGImage? {
    let (seconds, attoseconds) = time.components
    let exact = Double(seconds) + Double(attoseconds) / 1e18
    // A hair of tolerance, so a time computed as `index / framerate` lands on that index.
    return frame(index: Int((exact * Double(timeline.framerate) + 1e-6).rounded(.down)))
  }

  /// Output frame `index`, counted from the render's first frame as the CLI's file counts them.
  public func frame(index: Int) -> CGImage? {
    guard let context = CGContext(
      data: nil, width: style.width, height: style.height, bitsPerComponent: 8, bytesPerRow: 0,
      space: CGColorSpace(name: CGColorSpace.sRGB)!,
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return nil }

    context.setFillColor(background)
    context.fill(CGRect(origin: .zero, size: size))
    // Grayscale antialiasing with fractional glyph positions: what Skia produces here, where
    // its LCD flag has no pixel geometry to act on.
    context.setShouldAntialias(true)
    context.setShouldSmoothFonts(false)
    context.setAllowsFontSubpixelPositioning(true)
    context.setShouldSubpixelPositionFonts(true)

    let newest = timeline.newestIndex(at: timeline.updateTime(forFrame: index))
    var top = style.height
    var comment = newest
    // CR:760-800: newest at the bottom, each older one above it, until one would start above
    // the gap at the top; the last placed may be cut off by the frame.
    while comment >= 0, top > -style.verticalPadding {
      defer { comment -= 1 }
      guard let layout = layout(of: comment) else { continue }
      top -= layout.height(in: style) + style.verticalPadding
      draw(layout, top: top, in: context)
    }
    return context.makeImage()
  }

  private func layout(of index: Int) -> MessageLayout? {
    if let cached = layouts.withLock({ $0[index] }) { return cached }
    let layout = MessageLayout(
      comment: document.comments[index], style: style, messageColor: messageColor)
    layouts.withLock { $0[index] = .some(layout) }
    return layout
  }

  /// `top` is from the top of the frame, as the CLI measures; Core Graphics counts from the
  /// bottom.
  private func draw(_ layout: MessageLayout, top: Int, in context: CGContext) {
    for word in layout.words {
      let font = word.face == .bold ? style.bold : style.regular
      let baseline = top + word.line * style.sectionHeight + style.baseline
      let origin = CGPoint(x: Double(word.x), y: Double(style.height - baseline))

      context.setFillColor(word.color)
      // Glyph positions are offset by the text position, and CTLineDraw below moves it: without
      // this, every word drawn after a shaped one lands off the frame.
      context.textPosition = .zero
      if let run = GlyphRun.glyphs(of: Substring(word.text), in: font) {
        var x = origin.x
        let positions = run.advances.map { advance in
          defer { x += advance.width }
          return CGPoint(x: x, y: origin.y)
        }
        CTFontDrawGlyphs(font, run.glyphs, positions, run.glyphs.count, context)
      } else {
        context.textPosition = origin
        CTLineDraw(GlyphRun.shapedLine(Substring(word.text), font: font, color: word.color), context)
      }
    }
  }
}
