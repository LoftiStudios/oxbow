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

  /// Where a card comes in from, and how hard it is leaning when it does.
  ///
  /// **A real journey, not a nudge.** An earlier version parted the cards by
  /// their resting offsets — five points each — which is a motion you have to
  /// already be looking at to notice. Mail throws the whole message in from
  /// the side, and the distance is most of what sells it.
  private static let entry: CGFloat = 150
  private static let entryTurn: Double = -10

  /// Whether the cards have been dealt yet.
  ///
  /// **False for exactly one frame**, then they fly in from the right and land
  /// on the pile — Mail's motion when a multi-selection replaces a single one.
  ///
  /// Deliberately keyed to *appearing*, not to the count. Extending a
  /// selection by shift-clicking down a list would otherwise re-deal the whole
  /// pile on every row, which is four animations nobody asked for; a card
  /// added to a stack already on screen flies in on its own instead (see the
  /// `.animation` on the count below).
  @State private var dealt = false

  /// How far back in the pile a card sits. **The last one is on top.**
  ///
  /// Cards land on top of each other as they arrive, so the newest is
  /// frontmost — a pile being built, not a hand being fanned. An earlier
  /// version had this inverted, which made the first card the front one and
  /// meant the card a person's eye lands on was the one that never moved.
  private func depth(of index: Int) -> Int { thumbnails.count - 1 - index }

  var body: some View {
    ZStack {
      // Natural order, so a later card draws over an earlier one and the last
      // to arrive ends up on top.
      ForEach(Array(thumbnails.enumerated()), id: \.offset) { index, url in
        let back = depth(of: index)
        StackTile(url: url, store: store)
          .rotationEffect(
            .degrees(dealt ? Double(back) * Self.turn : Self.entryTurn),
            anchor: .bottomTrailing)
          .offset(
            x: dealt ? CGFloat(back) * -Self.slide : Self.entry,
            y: dealt ? CGFloat(back) * Self.drop : 0)
          // Every card flies in, including the one that ends up on top —
          // which is the whole point of dealing onto a pile rather than
          // fanning one out.
          .opacity(dealt ? 1 : 0)
          // Staggered in arrival order, so the pile visibly builds and the
          // last card to land is the one left facing you.
          .animation(
            .spring(response: 0.38, dampingFraction: 0.74)
              .delay(Double(index) * 0.06),
            value: dealt)
      }
    }
    // **Not `.onAppear`, and that was the bug.** Setting state from `onAppear`
    // is coalesced with the view's first render, so SwiftUI sees no *change*
    // and there is nothing to animate — the pile simply existed, fanned, from
    // the first frame. The collapsed state has to survive one real frame
    // before the spring starts, which is what the sleep buys.
    //
    // Keyed on the count rather than fired once: re-dealing when a card is
    // added is a second chance to see it, and a pile that rebuilds as you
    // shift-click down a list is closer to what Mail does than a pile that
    // animates once and then never moves again.
    .task(id: thumbnails.count) {
      dealt = false
      try? await Task.sleep(for: .milliseconds(16))
      // **Belt and braces, and they cover different failures.** The per-card
      // `.animation(_:value:)` above is what staggers the deal; this explicit
      // `withAnimation` is the floor if a `Form` row turns out to swallow
      // implicit animations, which `List`-backed containers on macOS have
      // been known to do. Where both apply the per-card one wins, so this
      // costs nothing when the stagger is working.
      withAnimation(.spring(response: 0.38, dampingFraction: 0.74)) {
        dealt = true
      }
    }
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
    // **The image swap gets its own, much shorter animation.** Without this
    // it inherits whatever the fan is running — a 0.38s spring — so a
    // thumbnail arriving mid-deal cross-fades on the spring's timing and the
    // two motions compete for the same moment. A nearer `.animation` wins for
    // this subtree, so the card can be flying in at spring speed while its
    // picture simply appears.
    //
    // Keyed on `image != nil` because `NSImage` is not `Equatable`; the only
    // transition worth animating here is empty-to-loaded anyway.
    .animation(.easeOut(duration: 0.12), value: image != nil)
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
