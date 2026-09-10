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
/// **Shows `section.rows` — the same filtered list the inbox does — for now.**
/// The unfiltered library is the next slice; keeping them apart means this
/// navigation can be judged before the data underneath it changes.
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
    List(selection: $selection) {
      ChannelCard(
        section: section,
        imageStore: imageStore,
        demotionReason: demotionReason,
        onEdit: onEdit,
        onStopWatching: onStopWatching)
        // Not an item in the list: it is the pane's header that happens to
        // live inside the scroll, so it takes no separator and cannot be
        // selected out from under the rows below it.
        .listRowSeparator(.hidden)
        .selectionDisabled(true)

      ForEach(section.rows) { row in
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
    .navigationTitle(section.displayName)
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
    return section.rows.first { $0.id == selection }
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

#Preview("A channel with findings and a download") {
  ChannelView(
    section: WatchingModel.Section(
      login: "leighxp", displayName: "LeighXP",
      rows: [
        WatchingModel.Row(
          archive: ChannelArchive(
            id: "1", title: "Indie horror night", duration: .seconds(3 * 3600),
            publishedAt: Date().addingTimeInterval(-86400),
            status: .recorded, thumbnailURL: nil),
          state: .available),
        WatchingModel.Row(
          archive: ChannelArchive(
            id: "2", title: "Patch notes and questions", duration: .seconds(5 * 3600),
            publishedAt: Date().addingTimeInterval(-9 * 86400),
            status: .recorded, thumbnailURL: nil),
          state: .downloaded(URL(filePath: "/Users/me/Movies/Patch notes.mp4"))),
      ],
      failure: nil,
      settingsSummary: "Video + chat · Best available · Medium chat · Downloads",
      downloadsAutomatically: true),
    imageStore: nil, demotionReason: nil,
    onAdd: { _ in }, onAddWithOptions: { _ in }, onIgnore: { _ in },
    onEdit: {}, onStopWatching: {})
  .frame(width: 560, height: 480)
}

#Preview("A channel with nothing in it") {
  // Slice D gives this a real `ContentUnavailableView`; today it is a header
  // over an empty list, which is honest but not yet good.
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
