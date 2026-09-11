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

  /// How far each deeper card slides and turns.
  ///
  /// **Rotated as well as offset**, which is the difference between a fan and
  /// a stepped column: a pile of photographs tossed down, not a spreadsheet.
  /// Small angles — past about five degrees per card the deepest one reads as
  /// broken rather than casual.
  private static let slide: CGFloat = 5
  private static let drop: CGFloat = 2
  private static let turn: Double = -3

  /// Whether the cards have dealt out of the front one yet.
  ///
  /// **False for exactly one frame.** The fan starts collapsed — every card
  /// squared up behind the front one — and springs apart on appear, which is
  /// the motion Mail uses when a multi-selection replaces a single one. It
  /// says "these several" in a way a static fan has to be read to say.
  ///
  /// Deliberately keyed to *appearing*, not to the count. Extending a
  /// selection by shift-clicking down a list would otherwise re-collapse and
  /// re-deal on every row, which is four animations nobody asked for; a card
  /// added to a fan already on screen slides in on its own instead (see the
  /// `.animation` on the count below).
  @State private var fanned = false

  var body: some View {
    ZStack {
      // Reversed so index 0 is drawn last and lands on top: the fan reads
      // front-to-back in the same order the queue does.
      ForEach(Array(thumbnails.enumerated()).reversed(), id: \.offset) { index, url in
        StackTile(url: url, store: store)
          .rotationEffect(
            .degrees(fanned ? Double(index) * Self.turn : 0), anchor: .bottomTrailing)
          .offset(
            x: fanned ? CGFloat(index) * -Self.slide : 0,
            y: fanned ? CGFloat(index) * Self.drop : 0)
          // Hidden while stacked so the deal reads as cards emerging from
          // behind the front one rather than a single card splitting apart.
          // The front card never fades: something is always there.
          .opacity(fanned || index == 0 ? 1 : 0)
          // Staggered, back card last, so the eye follows the deal outward.
          // Short enough that it is over before it can feel like waiting.
          .animation(
            .spring(response: 0.32, dampingFraction: 0.72)
              .delay(Double(index) * 0.04),
            value: fanned)
      }
    }
    // A card added to a fan already on screen animates into place rather than
    // popping — the other half of the rule `fanned`'s doc comment states.
    .animation(.spring(response: 0.32, dampingFraction: 0.8), value: thumbnails.count)
    .onAppear { fanned = true }
    // Room for the rotated corners of the deepest card, which otherwise clip
    // against the section's edge.
    // Exactly enough for the deepest card's own offset, so the fan's left
    // edge lines up with the text beneath it rather than floating inboard.
    .padding(.leading, CGFloat(max(thumbnails.count - 1, 0)) * Self.slide)
    .padding(.bottom, CGFloat(max(thumbnails.count - 1, 0)) * Self.drop + 8)
    // One image of "the things you picked", not four separate controls.
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("Thumbnails of the selected downloads")
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

  @State private var image: NSImage?

  var body: some View {
    Group {
      if let image {
        Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
      } else {
        Rectangle().fill(.quaternary)
          .overlay {
            Image(systemName: "photo")
              .font(.title2)
              .foregroundStyle(.tertiary)
          }
      }
    }
    // Fills the width it is given and keeps 16:9, so the fan scales with the
    // inspector rather than pinning itself to one column width.
    .aspectRatio(16.0 / 9.0, contentMode: .fit)
    .frame(maxWidth: .infinity)
    .clipShape(RoundedRectangle(cornerRadius: 6))
    // **Stroke and shadow both, and both are doing work.** Twitch frames are
    // photographic and frequently near-black at the edges, so without the
    // stroke the overlap reads as one smeared image; without the shadow the
    // cards read as flat cut-outs rather than a pile with depth. The offset
    // leans the same way the fan does, so each card's shadow falls on the one
    // behind it.
    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator))
    .shadow(color: .black.opacity(0.5), radius: 6, x: -2, y: 4)
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
    thumbnails: [nil, nil, nil, nil], store: nil)
    .padding()
    .frame(width: 300, height: 200)
}

#Preview("Two") {
  SelectionStack(thumbnails: [nil, nil], store: nil)
    .padding()
    .frame(width: 300, height: 200)
}
