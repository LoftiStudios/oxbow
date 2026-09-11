import AppKit
import OxbowKit
import SwiftUI

/// The selected downloads' thumbnails, fanned like Mail's multi-message
/// selection.
///
/// `docs/design/inspector.md` §5.1. It does the work a count alone cannot: it
/// says *these*, with their artwork, so a mis-selection is visible before you
/// act on it.
///
/// **The order is the caller's and it matters.** `MultiSelection.thumbnails`
/// is built in queue order rather than by iterating the selection `Set`, which
/// has none — a fan rendered straight from a `Set` would reshuffle on every
/// rebuild. This view must not sort, reverse, or otherwise have an opinion.
///
/// **A `nil` entry draws a tile, not a gap.** A job whose video has no record
/// or no thumbnail holds its place, so the fan's length keeps agreeing with
/// what is selected rather than quietly understating it.
struct SelectionStack: View {
  /// Already capped at four by `InspectorSubject.stack`. Not re-capped here:
  /// two places deciding how many fit is two places to disagree.
  let thumbnails: [URL?]
  let store: ImageStore?

  private static let tileWidth: CGFloat = 104
  private static let step: CGFloat = 16

  private var tileHeight: CGFloat { Self.tileWidth * 9 / 16 }

  var body: some View {
    ZStack(alignment: .topLeading) {
      // Reversed so index 0 ends up drawn last and therefore on top: the fan
      // reads front-to-back in the same order the queue does.
      ForEach(Array(thumbnails.enumerated()).reversed(), id: \.offset) { index, url in
        tile(url)
          .offset(
            x: CGFloat(index) * Self.step,
            y: CGFloat(index) * Self.step * 0.375)
      }
    }
    .frame(
      width: Self.tileWidth + CGFloat(max(thumbnails.count - 1, 0)) * Self.step,
      height: tileHeight + CGFloat(max(thumbnails.count - 1, 0)) * Self.step * 0.375,
      alignment: .topLeading)
    // One image of "the things you picked", not four separate controls.
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("Thumbnails of the selected downloads")
  }

  private func tile(_ url: URL?) -> some View {
    StackTile(url: url, store: store, width: Self.tileWidth)
  }
}

/// One card in the fan.
///
/// Follows `ArchiveThumbnail`'s fetch exactly — including both guards, which
/// are load-bearing rather than defensive: `.task(id:)` re-runs when the
/// selection changes, and `ImageStore.data(for:)` does not check cancellation,
/// so a stale fetch can land after the new task has already cleared the image
/// and put another video's picture here. A wrong thumbnail is a wrong claim
/// about what a download is.
private struct StackTile: View {
  let url: URL?
  let store: ImageStore?
  let width: CGFloat

  @State private var image: NSImage?

  var body: some View {
    Group {
      if let image {
        Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
      } else {
        Rectangle().fill(.quaternary)
          .overlay {
            Image(systemName: "photo")
              .font(.system(size: width * 0.2))
              .foregroundStyle(.tertiary)
          }
      }
    }
    .frame(width: width, height: width * 9 / 16)
    .clipShape(RoundedRectangle(cornerRadius: 5))
    // The stroke is what makes the overlap read as separate cards rather than
    // one smeared image — Twitch frames are photographic and frequently
    // near-black at the edges.
    .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(.separator))
    .shadow(color: .black.opacity(0.35), radius: 3, x: 0, y: 1)
    .task(id: url) {
      image = nil
      guard let url, let store else { return }
      guard let data = await store.data(for: url) else { return }
      guard !Task.isCancelled else { return }
      image = NSImage(data: data)
    }
  }
}

#Preview("Four, one without artwork") {
  SelectionStack(
    thumbnails: [nil, nil, nil, nil],
    store: nil)
    .padding()
    .frame(width: 300, height: 200)
}

#Preview("Two") {
  SelectionStack(thumbnails: [nil, nil], store: nil)
    .padding()
    .frame(width: 300, height: 200)
}
