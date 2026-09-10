import AppKit
import SwiftUI
import OxbowKit

/// One watched channel, as its own destination.
///
/// `docs/design/watching-navigation.md` §5. The rows are the same
/// `ArchiveRow`s the inbox draws, in the same states, with the same context
/// menus — this is a new place for rows that already render, not a new row.
///
/// **`ChannelCard` heads the pane and scrolls with it.** It is not a pinned
/// section header here, which is what §1 of that document is complaining
/// about: as a pinned header the card has no opaque background and the next
/// channel's card scrolls visibly through it. Nothing is above this one to
/// collide with, and the 88pt avatar is finally proportionate, because it is
/// heading a whole pane rather than repeating four times down one scroll.
///
/// **Shows `section.allRows` — the whole record, not the inbox's filtered
/// view.** Downloads, archives you skipped, ones you ignored, and headstones
/// for videos Twitch has since dropped. That is the point of the destination:
/// the inbox answers "what is waiting", and this answers "what does this
/// channel have".
struct ChannelView: View {
  let section: WatchingModel.Section
  let imageStore: ImageStore?
  /// Why this channel's automatic downloading is paused this sweep, or nil.
  /// Passed through to `ChannelCard` exactly as `WatchingView` passes it.
  let demotionReason: AutoDownloadPolicy.Reason?
  let onAdd: (ChannelArchive) -> Void
  let onAddWithOptions: (ChannelArchive) -> Void
  let onIgnore: (ChannelArchive) -> Void
  let onEdit: () -> Void
  let onStopWatching: () -> Void

  @Environment(\.openWindow) private var openWindow

  /// The row a person has picked, by archive id — the same single-selection
  /// model `WatchingView` uses, and for the same reason: nothing here acts on
  /// several rows at once.
  @State private var selection: WatchingModel.Row.ID?

  var body: some View {
    Group {
      if section.failure != nil || section.allRows.isEmpty {
        // **The card stays, even with nothing under it.**
        // `channel-watching.md` §3.2 froze a watch's settings at add time and
        // made this list the one place they can still be read — "or they
        // become state nobody can audit". A pane that replaced the card
        // wholesale with an empty state would hide the settings, and the Edit
        // that changes them, for exactly the channels most likely to need
        // both: the broken one and the one that has never produced anything.
        VStack(spacing: 0) {
          card
            // Matches the inset a `List` row gets, so the card does not shift
            // sideways between a channel that has rows and one that does not.
            .padding(.horizontal, 20)
          Divider()
          emptyState
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
      } else {
        list
      }
    }
    .navigationTitle(section.displayName)
  }

  private var card: some View {
    ChannelCard(
      section: section,
      imageStore: imageStore,
      demotionReason: demotionReason,
      onEdit: onEdit,
      onStopWatching: onStopWatching)
  }

  /// What stands where the rows would be.
  ///
  /// **Two states that must never be confused**, which is the whole reason
  /// `Section.failure` is distinct from `rows.isEmpty`: a broken sweep has to
  /// read as an error, never as a channel with nothing new. Alone in a pane
  /// the constraint that made `WatchingView`'s equivalents one-line labels is
  /// gone — there are no quiet channels beside this one to shout over — so
  /// they become the real thing, but the distinction they protect is
  /// unchanged.
  @ViewBuilder
  private var emptyState: some View {
    if let failure = section.failure {
      ContentUnavailableView {
        Label("Couldn't check \(section.displayName)",
              systemImage: "exclamationmark.triangle.fill")
      } description: {
        Text(failure)
      }
    } else {
      ContentUnavailableView {
        Label("Nothing to show for \(section.displayName)", systemImage: "tray")
      } description: {
        // Deliberately vague about *why*, the same way `EmptyChannelRow` is:
        // until something can tell an ignored archive from a channel that has
        // genuinely never published one, claiming either would be a guess.
        // `djjakerudh` reports `totalCount: 0` because a DJ's licensing keeps
        // him live-only, and that is not something this pane could know.
        Text("Oxbow hasn't seen any archives from this channel.")
      }
    }
  }

  private var list: some View {
    List(selection: $selection) {
      card
        // Not an item in the list: it is the pane's header that happens to
        // live inside the scroll, so it takes no separator and cannot be
        // selected out from under the rows below it.
        .listRowSeparator(.hidden)
        .selectionDisabled(true)

      ForEach(section.allRows) { row in
        ArchiveRow(
          row: row,
          store: imageStore,
          onAdd: { onAdd(row.archive) },
          onIgnore: { onIgnore(row.archive) },
          onAddWithOptions: { onAddWithOptions(row.archive) },
          onReveal: { NSWorkspace.shared.activateFileViewerSelecting([$0]) },
          onShowInfo: {
            openWindow(id: OxbowApp.infoWindowID, value: InfoTarget.video(row.archive.id))
          })
          // Double-click opens, the way it does in Finder and Music.
          // `simultaneousGesture` rather than `onTapGesture`, which would
          // swallow the single click the list needs to select with.
          .simultaneousGesture(TapGesture(count: 2).onEnded { open(row) })
      }
    }
    .listRowSeparator(.visible)
    // Return opens the selection, the keyboard's half of double-click.
    // Unhandled when nothing is selected or the row has no file, so the key
    // keeps its ordinary meaning everywhere else in the window.
    .onKeyPress(.return) {
      guard let url = selectedRow?.state.openableFile else { return .ignored }
      NSWorkspace.shared.open(url)
      return .handled
    }
  }

  private var selectedRow: WatchingModel.Row? {
    guard let selection else { return nil }
    return section.allRows.first { $0.id == selection }
  }

  /// Opens the row's file in whatever plays it.
  ///
  /// **Only a file actually on disk opens**, and opening is the only thing
  /// this gesture does: `docs/design/video-record.md` §4.3 rules out letting a
  /// double-click start a download, because a gesture you can trigger by
  /// clicking twice must never commit somebody to twenty gigabytes.
  private func open(_ row: WatchingModel.Row) {
    guard let url = row.state.openableFile else { return }
    NSWorkspace.shared.open(url)
  }
}

/// The whole point of the destination, in one screen: the inbox would show
/// only the first of these three, and this shows what the channel *has*.
#Preview("A channel's whole record") {
  func archive(_ id: String, _ title: String, daysAgo: Double) -> ChannelArchive {
    ChannelArchive(
      id: id, title: title, duration: .seconds(3 * 3600),
      publishedAt: Date().addingTimeInterval(-daysAgo * 86400),
      status: .recorded, thumbnailURL: nil)
  }

  let waiting = WatchingModel.Row(
    archive: archive("1", "Indie horror night", daysAgo: 1), state: .available)
  let kept = WatchingModel.Row(
    archive: archive("2", "Patch notes and questions", daysAgo: 9),
    state: .downloaded(URL(filePath: "/Users/me/Movies/Patch notes.mp4")))
  let headstone = WatchingModel.Row(
    archive: archive("3", "A stream from before the record existed", daysAgo: 200),
    state: .expired)

  return ChannelView(
    section: WatchingModel.Section(
      login: "leighxp", displayName: "LeighXP",
      // `rows` is what the inbox would draw; `allRows` is what this pane does.
      rows: [waiting],
      allRows: [waiting, kept, headstone],
      failure: nil,
      settingsSummary: "Video + chat · Best available · Medium chat · Downloads",
      downloadsAutomatically: true),
    imageStore: nil, demotionReason: nil,
    onAdd: { _ in }, onAddWithOptions: { _ in }, onIgnore: { _ in },
    onEdit: {}, onStopWatching: {})
  .frame(width: 560, height: 480)
}

#Preview("A channel with nothing in it") {
  ChannelView(
    section: WatchingModel.Section(
      login: "djjakerudh", displayName: "djjakerudh", rows: [], failure: nil,
      settingsSummary: "Video · Up to 720p · Downloads",
      downloadsAutomatically: false),
    imageStore: nil, demotionReason: nil,
    onAdd: { _ in }, onAddWithOptions: { _ in }, onIgnore: { _ in },
    onEdit: {}, onStopWatching: {})
  .frame(width: 560, height: 480)
}

// The pair that must never be confused with each other: this one broke, the
// one above is simply empty. Two different icons, two different sentences,
// and this one carries the error's own text.
#Preview("A channel whose sweep failed") {
  ChannelView(
    section: WatchingModel.Section(
      login: "brokenchannel", displayName: "A Broken Channel", rows: [],
      failure: "The response did not include the expected video list.",
      settingsSummary: "Video · Up to 1080p · Downloads",
      downloadsAutomatically: false),
    imageStore: nil, demotionReason: nil,
    onAdd: { _ in }, onAddWithOptions: { _ in }, onIgnore: { _ in },
    onEdit: {}, onStopWatching: {})
  .frame(width: 560, height: 480)
}
