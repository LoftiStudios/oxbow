import AppKit
import OxbowKit
import SwiftUI

/// Arrival order, oldest first. Only four depths are visible; older selections
/// stay directly behind the fourth card so they can leave from that position.
struct SelectionStack: View {
  let cards: [StackCard]
  let store: ImageStore?

  private static let slide: CGFloat = 5
  private static let drop: CGFloat = 2
  private static let turn: Double = -3
  private static let entry: CGFloat = 150
  private static let settle = Animation.spring(response: 0.38, dampingFraction: 0.8)

  /// Keep departing cards mounted until their motion finishes. Layer numbers
  /// never change as neighbours leave, including during rapid reselection.
  private struct Tile: Identifiable {
    var card: StackCard
    var id: JobID { card.id }
    var layer: Double
    var depth: Int
    var away = true
    var departing = false
    var castsShadow = true
  }

  @State private var tiles: [Tile] = []
  @State private var nextLayer: Double = 1

  var body: some View {
    ZStack {
      ForEach(tiles) { tile in
        StackTile(url: tile.card.url, store: store, castsShadow: tile.castsShadow)
          .rotationEffect(.degrees(Double(tile.depth) * Self.turn), anchor: .bottomTrailing)
          .offset(
            x: CGFloat(tile.depth) * -Self.slide + (tile.away ? Self.entry : 0),
            y: CGFloat(tile.depth) * Self.drop)
          .opacity(tile.away ? 0 : 1)
          .zIndex(tile.layer)
      }
    }
    .task(id: cards) {
      // Mount newcomers off to the side first. Animating properties of an
      // existing tile also works inside Form, where insertion transitions can
      // be coalesced with the row's update.
      for (index, card) in cards.enumerated() {
        if let existing = tiles.firstIndex(where: { $0.id == card.id }) {
          tiles[existing].card = card
          if tiles[existing].departing {
            tiles[existing].layer = nextLayer
            nextLayer += 1
          }
        } else {
          tiles.append(Tile(
            card: card, layer: nextLayer, depth: min(cards.count - 1 - index, 3)))
          nextLayer += 1
        }
      }
      do { try await Task.sleep(for: .milliseconds(16)) } catch { return }
      withAnimation(Self.settle) {
        for index in tiles.indices {
          if let position = cards.firstIndex(where: { $0.id == tiles[index].id }) {
            tiles[index].depth = min(cards.count - 1 - position, 3)
            tiles[index].departing = false
            tiles[index].away = false
            tiles[index].castsShadow = cards.count - 1 - position < 4
          } else {
            // Preserve the old depth, even for a card behind the visible four.
            tiles[index].departing = true
            tiles[index].away = true
            tiles[index].castsShadow = true
          }
        }
      }
      // A changed selection cancels this cleanup. The next update retains
      // ongoing departures and can reverse one if it was selected again.
      do { try await Task.sleep(for: .milliseconds(700)) } catch { return }
      tiles.removeAll { $0.away }
    }
    .padding(.leading, CGFloat(min(max(cards.count - 1, 0), 3)) * Self.slide)
    .padding(.bottom, CGFloat(min(max(cards.count - 1, 0), 3)) * Self.drop + 8)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("Thumbnails of the selected downloads")
  }
}

/// Guard stale image fetches as ArchiveThumbnail does: ImageStore.data(for:) does not check
/// cancellation, so an old result may arrive after selection changes.
private struct StackTile: View {
  let url: URL?
  let store: ImageStore?
  var castsShadow = true

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
    // Use a short image fade instead of inheriting the fan's spring. Key on image presence
    // because NSImage is not Equatable.
    .animation(.easeOut(duration: 0.12), value: image != nil)
    .aspectRatio(16.0 / 9.0, contentMode: .fit)
    .frame(maxWidth: .infinity)
    .background(.background)
    .clipShape(RoundedRectangle(cornerRadius: 6))
    // A border separates dark image edges; the shadow shows depth between overlapping cards.
    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator))
    .shadow(color: .black.opacity(castsShadow ? 0.5 : 0), radius: 6, x: -2, y: 4)
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
