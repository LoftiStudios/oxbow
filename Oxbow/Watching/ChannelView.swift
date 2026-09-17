import AppKit
import SwiftUI
import OxbowKit

/// Whole channel history using shared ArchiveRows and a scrolling ChannelCard. Render allRows,
/// including handled and expired videos, rather than the inbox's filtered rows.
struct ChannelView: View {
  let section: WatchingModel.Section
  let imageStore: ImageStore?
  let demotionReason: AutoDownloadPolicy.Reason?
  let onAdd: (ChannelArchive) -> Void
  let onAddWithOptions: (ChannelArchive) -> Void
  let onIgnore: (ChannelArchive) -> Void
  let onEdit: () -> Void
  let onStopWatching: () -> Void

  @Environment(\.openWindow) private var openWindow

  /// Share archive selection with QueueView for the inspector.
  @Binding var selection: WatchingModel.Row.ID?

  var body: some View {
    Group {
      if section.failure != nil || section.allRows.isEmpty {
        // Keep the channel card visible when empty or failed so frozen settings and Edit remain
        // accessible.
        VStack(spacing: 0) {
          card
            // Match List row insets in the empty state.
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

  /// Distinguish failed sweeps from successfully empty history.
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
        // Do not infer why no archives were observed.
        Text("Oxbow hasn't seen any archives from this channel.")
      }
    }
  }

  private var list: some View {
    List(selection: $selection) {
      card
        // The scrolling channel header is not a selectable archive row.
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
          // Simultaneous double-click handling preserves List's single-click selection.
          .simultaneousGesture(TapGesture(count: 2).onEnded { open(row) })
      }
    }
    .listRowSeparator(.visible)
    // Return opens selected files; leave the key unhandled otherwise.
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

  /// Open only an existing downloaded file. Double-click must never initiate a download.
  private func open(_ row: WatchingModel.Row) {
    guard let url = row.state.openableFile else { return }
    NSWorkspace.shared.open(url)
  }
}

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
      rows: [waiting],
      allRows: [waiting, kept, headstone],
      failure: nil,
      settingsSummary: "Video + chat · Best available · Medium chat · Downloads",
      downloadsAutomatically: true),
    imageStore: nil, demotionReason: nil,
    onAdd: { _ in }, onAddWithOptions: { _ in }, onIgnore: { _ in },
    onEdit: {}, onStopWatching: {}, selection: .constant(nil))
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
    onEdit: {}, onStopWatching: {}, selection: .constant(nil))
  .frame(width: 560, height: 480)
}

#Preview("A channel whose sweep failed") {
  ChannelView(
    section: WatchingModel.Section(
      login: "brokenchannel", displayName: "A Broken Channel", rows: [],
      failure: "The response did not include the expected video list.",
      settingsSummary: "Video · Up to 1080p · Downloads",
      downloadsAutomatically: false),
    imageStore: nil, demotionReason: nil,
    onAdd: { _ in }, onAddWithOptions: { _ in }, onIgnore: { _ in },
    onEdit: {}, onStopWatching: {}, selection: .constant(nil))
  .frame(width: 560, height: 480)
}
