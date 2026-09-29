import CoreGraphics
import Foundation

/// A chat render as a function of time rather than a loop, so any frame can be drawn on its
/// own: for a preview, a resumed composite, or a file written front to back.
/// docs/design/native-chat-render.md §4.
public protocol ChatFrameSource: Sendable {
  var size: CGSize { get }
  /// From the chat file's start to its end — its trim, when it has one — as the CLI's render
  /// runs (CR:2145-2147).
  var duration: Duration { get }
  func frame(at time: Duration) -> CGImage?
}
