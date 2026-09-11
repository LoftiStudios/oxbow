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
/// **The order is the caller's and it matters.** `MultiSelection.cards` is
/// built in *arrival* order — oldest first, so the newest lands on top — and
/// capped by dropping the oldest. This view must not sort, reverse, or
/// otherwise have an opinion; it only draws depth from position.
///
/// **A nil `url` draws a tile, not a gap.** A job whose video has no record or
/// no thumbnail holds its place, so the pile's height keeps agreeing with what
/// is selected rather than quietly understating it.
struct SelectionStack: View {
  /// Oldest first, newest last — the last one is on top. Already capped at
  /// four by `InspectorSubject.stack`, which drops the *oldest* to make room.
  /// Not re-capped here: two places deciding how many fit is two places to
  /// disagree.
  let cards: [StackCard]
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

  /// Whether the opening deal has run.
  ///
  /// **Once, on appear, and never again.** The pile builds itself after that:
  /// a card added to a stack already on screen flies in as *itself* and a card
  /// removed flies out, because each carries a stable id and its own
  /// transition. Re-dealing the whole pile on every change was what made
  /// extending a selection upward look like the same card landing five times.
  @State private var dealt = false

  /// How far back in the pile a card sits. **The last one is on top.**
  ///
  /// Cards land on top of each other as they arrive, so the newest is
  /// frontmost — a pile being built, not a hand being fanned.
  private func depth(of index: Int) -> Int { cards.count - 1 - index }

  var body: some View {
    ZStack {
      // Natural order, so a later card draws over an earlier one and the last
      // to arrive ends up on top. Keyed by `StackCard.id`, which is what lets
      // an insertion or a removal animate as one card rather than as a pile
      // of a different length.
      ForEach(Array(cards.enumerated()), id: \.element.id) { index, card in
        let back = depth(of: index)
        StackTile(url: card.url, store: store)
          .rotationEffect(
            .degrees(dealt ? Double(back) * Self.turn : Self.entryTurn),
            anchor: .bottomTrailing)
          .offset(
            x: dealt ? CGFloat(back) * -Self.slide : Self.entry,
            y: dealt ? CGFloat(back) * Self.drop : 0)
          .opacity(dealt ? 1 : 0)
          // The opening deal only. Staggered in arrival order, so the pile
          // visibly builds and the last card to land faces you.
          .animation(
            .spring(response: 0.38, dampingFraction: 0.74)
              .delay(Double(index) * 0.06),
            value: dealt)
          // Afterwards: in from the side, out the same way. Symmetric, so
          // deselecting reads as the undo of selecting rather than as the
          // pile silently becoming shorter.
          .transition(.offset(x: Self.entry).combined(with: .opacity))
      }
    }
    // Drives the transitions above, and slides the survivors back a place when
    // one is added or dropped.
    .animation(.spring(response: 0.38, dampingFraction: 0.8), value: cards)
    // **Not `.onAppear`.** Setting state there is coalesced with the view's
    // first render, so SwiftUI sees no change and there is nothing to animate
    // — the pile simply existed, already fanned, from the first frame. The
    // collapsed state has to survive one real frame before the spring starts,
    // which is what the sleep buys.
    //
    // No `id:`, so this runs once for the life of the stack. Additions and
    // removals are the transitions' business, not this one's.
    .task {
      try? await Task.sleep(for: .milliseconds(16))
      withAnimation(.spring(response: 0.38, dampingFraction: 0.74)) {
        dealt = true
      }
    }
    // Room for the rotated corners of the deepest card, which otherwise clip
    // against the section's edge. Exactly enough for the deepest card's own
    // offset, so the fan's left edge lines up with the text beneath it.
    .padding(.leading, CGFloat(max(cards.count - 1, 0)) * Self.slide)
    .padding(.bottom, CGFloat(max(cards.count - 1, 0)) * Self.drop + 8)
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

private func previewCards(_ n: Int) -> [StackCard] {
  (0..<n).map { _ in StackCard(id: JobID(rawValue: UUID()), url: nil) }
}

#Preview("Four") {
  SelectionStack(cards: previewCards(4), store: nil)
    .padding()
    .frame(width: 300, height: 200)
}

#Preview("Two") {
  SelectionStack(cards: previewCards(2), store: nil)
    .padding()
    .frame(width: 300, height: 200)
}
