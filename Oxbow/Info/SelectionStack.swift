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

  /// The cards actually on screen, which trails `cards` during the opening
  /// deal and matches it thereafter.
  ///
  /// **One mechanism for every motion.** The deal, an addition and a removal
  /// are all just this array changing, so they all animate through the same
  /// transition and cannot disagree. The previous version drove the deal with
  /// a separate `dealt` flag and a per-card `.animation(_:value:)`, which
  /// overrode the container's animation for every card whose `dealt` had not
  /// changed — so survivors snapped to their new depth while one card moved.
  @State private var visible: [StackCard] = []

  /// How far back in the pile a card sits. **The last one is on top.**
  ///
  /// Cards land on top of each other as they arrive, so the newest is
  /// frontmost — a pile being built, not a hand being fanned.
  private func depth(of index: Int) -> Int { visible.count - 1 - index }

  var body: some View {
    ZStack {
      ForEach(Array(visible.enumerated()), id: \.element.id) { index, card in
        let back = depth(of: index)
        StackTile(url: card.url, store: store)
          .rotationEffect(.degrees(Double(back) * Self.turn), anchor: .bottomTrailing)
          .offset(x: CGFloat(back) * -Self.slide, y: CGFloat(back) * Self.drop)
          // **Explicit, and load-bearing during a transition.** A `ZStack`
          // draws a `ForEach` in order, but a view being inserted or removed
          // is composited outside that order — so without this the card flying
          // in could land *behind* the pile, which reads as the bottom
          // thumbnail animating rather than the new one.
          .zIndex(Double(index))
          // **In from the side always; out two different ways.**
          //
          // A card leaves for one of two reasons, and they do not look alike.
          // Deselecting dismisses a card you can see, so it flies out the way
          // it came in — the undo of selecting it. Being *pushed off the
          // bottom* by a newer arrival is not a dismissal at all: that card is
          // at the back of the pile, largely hidden, and the motion worth
          // watching is the new one landing on top. Flying it out sideways
          // made the eye follow the wrong card entirely.
          //
          // Told apart by position rather than by cause, which needs no extra
          // state: the card pushed off is always the deepest one, and the
          // deepest card is the one you can least see. It fades whatever sent
          // it away — including a deselect, where flying a mostly-occluded
          // card out from behind the others would look stranger than a fade.
          //
          // The last card standing is the front one, so it flies.
          .transition(.asymmetric(
            insertion: .offset(x: Self.entry).combined(with: .opacity),
            removal: index == 0 && visible.count > 1
              ? .opacity
              : .offset(x: Self.entry).combined(with: .opacity)))
      }
    }
    .animation(.spring(response: 0.38, dampingFraction: 0.8), value: visible)
    // The opening deal is the same insertion, one card at a time. No separate
    // animation path, so it cannot drift from what an addition does later.
    //
    // The first sleep is what makes any of it animate at all: state set in the
    // same pass as the first render is coalesced with it, and SwiftUI sees no
    // change to animate.
    .task {
      try? await Task.sleep(for: .milliseconds(16))
      for card in cards where !visible.contains(card) {
        visible.append(card)
        try? await Task.sleep(for: .milliseconds(55))
      }
      visible = cards
    }
    // After the deal, the pile follows the selection directly: one card in, or
    // one card out, each animating as itself because ids are stable.
    .onChange(of: cards) { _, now in visible = now }
    // Room for the rotated corners of the deepest card, which otherwise clip
    // against the section's edge. Exactly enough for the deepest card's own
    // offset, so the fan's left edge lines up with the text beneath it.
    .padding(.leading, CGFloat(max(visible.count - 1, 0)) * Self.slide)
    .padding(.bottom, CGFloat(max(visible.count - 1, 0)) * Self.drop + 8)
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
