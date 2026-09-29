import CoreGraphics
// CTFont is immutable and documented thread-safe, but not yet annotated Sendable.
@preconcurrency import CoreText
import Foundation
import Synchronization

/// Draws the chat column natively, matching the CLI's render of the same file. Text, with every
/// appearance option `RenderRequest` carries; no badges, emotes or emoji images yet.
/// docs/design/native-chat-render.md §6, phase 1.
///
/// Any frame can be drawn on its own. The CLI builds each redraw from the last, but what it
/// carries between them is a cache, not state: the newest visible comment fixes the whole frame
/// (see `ChatTimeline.newestIndex`), and comments stack upward from it.
public final class NativeChatRenderer: ChatFrameSource {
  public let size: CGSize

  private let document: ChatDocument
  private let timeline: ChatTimeline
  private let style: ChatTextStyle
  private let appearance: ChatAppearance
  /// Laid-out comments by index; nil where the CLI skips the comment. Layout is the expensive
  /// part of a frame and a comment appears in hundreds of them.
  private let layouts = Mutex<[Int: MessageLayout?]>([:])

  public init(document: ChatDocument, request: RenderRequest) {
    self.document = document
    size = CGSize(width: request.width, height: request.height)
    timeline = ChatTimeline(document: document, framerate: request.framerate)
    style = ChatTextStyle(width: request.width, height: request.height, fontSize: request.fontSize)
    appearance = ChatAppearance(request: request)
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
    guard let context = makeContext(data: nil) else { return nil }
    draw(frame: index, in: context)
    return context.makeImage()
  }

  /// Frame `index` as tightly packed RGBA, top row first — what FFmpeg reads as `-pix_fmt rgba`.
  /// Premultiplied, which is the same thing while the background is opaque.
  public func rgba(frame index: Int) -> Data {
    var data = Data(count: style.width * style.height * 4)
    data.withUnsafeMutableBytes { buffer in
      guard let context = makeContext(data: buffer.baseAddress) else { return }
      draw(frame: index, in: context)
    }
    return data
  }

  /// Frames with the same key are the same picture: what is drawn depends only on the newest
  /// visible comment. A writer can render once per key rather than once per frame — the CLI
  /// redraws every sixth frame, and most of those change nothing either.
  public func contentKey(forFrame index: Int) -> Int {
    timeline.newestIndex(at: timeline.updateTime(forFrame: index))
  }

  private func makeContext(data: UnsafeMutableRawPointer?) -> CGContext? {
    CGContext(
      data: data, width: style.width, height: style.height, bitsPerComponent: 8,
      bytesPerRow: style.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
  }

  private func draw(frame index: Int, in context: CGContext) {
    context.setFillColor(appearance.background.cgColor)
    context.fill(CGRect(origin: .zero, size: size))
    // Grayscale antialiasing with fractional glyph positions: what Skia produces here, where
    // its LCD flag has no pixel geometry to act on.
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
      let height = layout.height(in: style)
      top -= height + style.verticalPadding
      drawBackground(forComment: comment, top: top, height: height, in: context)
      draw(layout, top: top, in: context)
    }
  }

  private func layout(of index: Int) -> MessageLayout? {
    if let cached = layouts.withLock({ $0[index] }) { return cached }
    let layout = MessageLayout(
      comment: document.comments[index], index: index, offset: timeline.offsets[index],
      style: style, appearance: appearance)
    layouts.withLock { $0[index] = .some(layout) }
    return layout
  }

  /// CR:773-778: half a gap above and below the comment, so stripes meet. Not antialiased, as
  /// the CLI's paint is not; the half-pixel edges round rather than blur.
  private func drawBackground(forComment index: Int, top: Int, height: Int, in context: CGContext) {
    let color = appearance.background(forComment: index)
    guard color != appearance.background else { return }
    let padding = Double(style.verticalPadding)
    let fromTop = Double(top) - padding / 2
    let rect = CGRect(
      x: 0, y: Double(style.height) - fromTop - Double(height) - padding,
      width: Double(style.width), height: Double(height) + padding)
    context.saveGState()
    context.setShouldAntialias(false)
    context.setBlendMode(.copy)
    context.setFillColor(color.cgColor)
    context.fill(rect)
    context.restoreGState()
  }

  /// `top` is from the top of the frame, as the CLI measures; Core Graphics counts from the
  /// bottom.
  private func draw(_ layout: MessageLayout, top: Int, in context: CGContext) {
    for word in layout.words {
      if word.face == .emoji {
        drawEmoji(word, lineTop: top + word.line * style.sectionHeight, in: context)
        continue
      }
      let font = word.face == .bold ? style.bold : style.regular
      let baseline = top + word.line * style.sectionHeight + style.baseline
      let origin = CGPoint(x: Double(word.x), y: Double(style.height - baseline))
      let glyphs = Self.glyphs(of: word, font: font, origin: origin)

      // CR:1625-1632: the outline is stroked under the fill, word by word.
      if appearance.hasOutline {
        let path = CGMutablePath()
        for run in glyphs {
          for (glyph, position) in zip(run.glyphs, run.positions) {
            guard let outline = CTFontCreatePathForGlyph(run.font, glyph, nil) else { continue }
            path.addPath(outline, transform: CGAffineTransform(translationX: position.x, y: position.y))
          }
        }
        context.saveGState()
        context.setLineWidth(appearance.outlineWidth)
        context.setLineJoin(.round)
        context.setStrokeColor(ChatColor.black.cgColor)
        context.addPath(path)
        context.strokePath()
        context.restoreGState()
      }

      context.setFillColor(word.color.cgColor)
      // Glyph positions are offset by the text position, which CTLineDraw moves and saving the
      // graphics state does not restore: without this, everything drawn after an emoji shifts.
      context.textPosition = .zero
      for run in glyphs {
        CTFontDrawGlyphs(run.font, run.glyphs, run.positions, run.glyphs.count, context)
      }
    }
  }

  /// Apple's artwork in the CLI's box: its ink scaled to fit the square and centred in it, the
  /// square placed where the CLI places its Noto image. Not outlined, as the CLI's images are
  /// not.
  private func drawEmoji(_ word: MessageLayout.Word, lineTop: Int, in context: CGContext) {
    let font = CTFontCreateWithName("AppleColorEmoji" as CFString, style.fontSize, nil)
    let line = GlyphRun.shapedLine(Substring(word.text), font: font, color: nil)
    context.textPosition = .zero
    let ink = CTLineGetImageBounds(line, context)
    guard ink.width > 0, ink.height > 0 else { return }

    let box = Double(style.emojiSize)
    let scale = box / max(ink.width, ink.height)
    let left = Double(word.x + style.emojiInset) + (box - ink.width * scale) / 2
    let bottom = Double(style.height - lineTop - style.emojiTop - style.emojiSize)
      + (box - ink.height * scale) / 2
    context.saveGState()
    context.translateBy(x: left - ink.minX * scale, y: bottom - ink.minY * scale)
    context.scaleBy(x: scale, y: scale)
    context.textPosition = .zero
    CTLineDraw(line, context)
    context.restoreGState()
    context.textPosition = .zero
  }

  private struct PositionedGlyphs {
    let font: CTFont
    let glyphs: [CGGlyph]
    let positions: [CGPoint]
  }

  /// A word's glyphs at absolute positions, unshaped where the font covers it and shaped by
  /// Core Text, with fallback fonts, where it does not. Absolute because drawing a shaped line
  /// moves the context's text position, which offsets everything drawn after it.
  private static func glyphs(of word: MessageLayout.Word, font: CTFont, origin: CGPoint) -> [PositionedGlyphs] {
    if let run = GlyphRun.glyphs(of: Substring(word.text), in: font) {
      var x = origin.x
      let positions = run.advances.map { advance in
        defer { x += advance.width }
        return CGPoint(x: x, y: origin.y)
      }
      return [PositionedGlyphs(font: font, glyphs: run.glyphs, positions: positions)]
    }

    let line = GlyphRun.shapedLine(Substring(word.text), font: font, color: nil)
    let runs = (CTLineGetGlyphRuns(line) as? [CTRun]) ?? []
    return runs.map { run in
      let count = CTRunGetGlyphCount(run)
      var glyphs = [CGGlyph](repeating: 0, count: count)
      var positions = [CGPoint](repeating: .zero, count: count)
      CTRunGetGlyphs(run, CFRange(location: 0, length: count), &glyphs)
      CTRunGetPositions(run, CFRange(location: 0, length: count), &positions)
      let attributes = CTRunGetAttributes(run) as NSDictionary
      let runFont = attributes[kCTFontAttributeName] as! CTFont? ?? font
      return PositionedGlyphs(
        font: runFont, glyphs: glyphs,
        positions: positions.map { CGPoint(x: origin.x + $0.x, y: origin.y + $0.y) })
    }
  }
}
