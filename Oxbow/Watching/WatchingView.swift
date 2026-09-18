import AppKit
import SwiftUI
import OxbowKit

/// Channel-grouped inbox. Distinguish sweep failure, empty findings, and paused automatic
/// downloading; demotion explanations accompany findings rather than replace them.
struct WatchingView: View {
  let sections: [WatchingModel.Section]
  /// Distinguish an in-flight sweep from an empty watch list before results arrive.
  let isSweeping: Bool
  /// Per-sweep demotion reasons supplied by WatchPoller; stored automatic intent alone cannot
  /// explain a pause.
  let demotions: [String: AutoDownloadPolicy.Reason]

  /// Share selection with QueueView for the inspector.
  @Binding var selection: WatchingModel.Row.ID?

  @Environment(\.openWindow) private var openWindow

  var imageStore: ImageStore? = nil

  let onAdd: (ChannelArchive, WatchingModel.Section) -> Void

  /// The row's secondary action — see `ArchiveRow.onAddWithOptions`.
  var onAddWithOptions: (ChannelArchive, WatchingModel.Section) -> Void = { _, _ in }
  let onIgnore: (ChannelArchive, WatchingModel.Section) -> Void
  /// Open the shared Add Channel window with this watch's frozen settings.
  let onEdit: (WatchingModel.Section) -> Void
  /// Stop the selected watch without deleting delivered files or requesting confirmation.
  let onStopWatching: (WatchingModel.Section) -> Void
  /// Display the model's Stop Watching refusal.
  let stopWatchingFailure: String?
  /// Display seen-state persistence failures.
  let markSeenFailure: String?

  /// Display enqueue refusal separately from seen-state persistence failure.
  var submissionFailure: String? = nil

  var body: some View {
    VStack(spacing: 0) {
      if let stopWatchingFailure {
        QueueBanner(title: "Couldn't stop watching", message: stopWatchingFailure)
        Divider()
      }
      if let markSeenFailure {
        QueueBanner(title: "Couldn't save that", message: markSeenFailure)
        Divider()
      }
      if let submissionFailure {
        QueueBanner(title: "Couldn't queue that", message: submissionFailure)
        Divider()
      }
      content
        // Return opens selected files; leave it unhandled when no file is available.
        .onKeyPress(.return) {
          guard let url = selectedRow?.state.openableFile else { return .ignored }
          NSWorkspace.shared.open(url)
          return .handled
        }
    }
  }

  @ViewBuilder
  private var content: some View {
    if sections.isEmpty {
      if isSweeping {
        // Keep loading distinct from no watched channels.
        ContentUnavailableView {
          Label("Checking your channels", systemImage: "eye")
        } description: {
          Text("Looking for new videos. This can take a while with several channels.")
        }
      } else {
        ContentUnavailableView {
          Label("No channels watched yet", systemImage: "eye")
        }
      }
    } else {
      List(selection: $selection) {
        ForEach(sections) { section in
          Section {
            if let failure = section.failure {
              FailureRow(message: failure)
            } else {
              // Demotion pauses only automatic submission; keep findings visible. Suppress
              // destination demotion text when the card already explains that disconnection.
              if let reason = demotions[section.login],
                 !(reason.isDestinationUnreachable && section.disconnectedDestination != nil)
              {
                DemotionRow(reason: reason)
              }
              // Explain an empty section without inferring why it has no visible archives.
              if section.rows.isEmpty {
                EmptyChannelRow()
              }
              ForEach(section.rows) { row in
                ArchiveRow(
                  row: row,
                  store: imageStore,
                  onAdd: { onAdd(row.archive, section) },
                  onIgnore: { onIgnore(row.archive, section) },
                  onAddWithOptions: { onAddWithOptions(row.archive, section) },
                  onReveal: { NSWorkspace.shared.activateFileViewerSelecting([$0]) },
                  onShowInfo: {
                    openWindow(id: OxbowApp.infoWindowID, value: InfoTarget.video(row.archive.id))
                  })
                  // Simultaneous double-click preserves List single-click selection.
                  .simultaneousGesture(TapGesture(count: 2).onEnded { open(row) })
              }
            }
          } header: {
            ChannelCard(
              section: section,
              imageStore: imageStore,
              demotionReason: demotions[section.login],
              onEdit: { onEdit(section) },
              onStopWatching: { onStopWatching(section) })
          }
        }
      }
      // Separate rows with rules rather than alternating stripes.
      .listRowSeparator(.visible)
    }
  }

  /// Archive ids are globally unique, so selection needs no channel key.
  private var selectedRow: WatchingModel.Row? {
    guard let selection else { return nil }
    return sections.lazy.flatMap(\.rows).first { $0.id == selection }
  }

  /// Open existing downloaded files only. Double-click must not initiate a download.
  private func open(_ row: WatchingModel.Row) {
    guard let url = row.state.openableFile else { return }
    NSWorkspace.shared.open(url)
  }

}

/// Show fetch errors within the affected channel's section.
private struct FailureRow: View {
  let message: String

  var body: some View {
    Label {
      Text(message)
        .foregroundStyle(.secondary)
        // Wrap arbitrary localized error messages.
        .fixedSize(horizontal: false, vertical: true)
    } icon: {
      Image(systemName: "exclamationmark.triangle.fill")
        .foregroundStyle(.orange)
    }
    .padding(.vertical, 4)
    .accessibilityElement(children: .combine)
  }
}

/// Explain paused automatic submission beside findings, using the card's paused icon rather
/// than the fetch-failure triangle.
private struct DemotionRow: View {
  let reason: AutoDownloadPolicy.Reason

  var body: some View {
    Label {
      Text(reason.sentence)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    } icon: {
      Image(systemName: "pause.circle.fill")
        .foregroundStyle(.orange)
    }
    .padding(.vertical, 4)
    .accessibilityElement(children: .combine)
  }
}

/// Quiet empty-channel message without guessing a cause.
private struct EmptyChannelRow: View {
  var body: some View {
    Label {
      Text("Nothing to show for this channel.")
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    } icon: {
      Image(systemName: "tray")
        .foregroundStyle(.tertiary)
    }
    .padding(.vertical, 4)
    .accessibilityElement(children: .combine)
  }
}

#Preview("A channel with nothing in it") {
  WatchingView(
    sections: [
      WatchingModel.Section(
        login: "djjakerudh", displayName: "djjakerudh", avatarURL: nil,
        rows: [], failure: nil,
        settingsSummary: "Video · Up to 720p · Downloads",
        downloadsAutomatically: false)
    ],
    isSweeping: false, demotions: [:], selection: .constant(nil),
    onAdd: { _, _ in }, onIgnore: { _, _ in }, onEdit: { _ in }, onStopWatching: { _ in },
    stopWatchingFailure: nil, markSeenFailure: nil)
}

#Preview("Two channels, findings") {
  WatchingView(
    sections: [
      WatchingModel.Section(
        login: "leighxp", displayName: "LeighXP",
        rows: [WatchingViewPreviewData.normal, WatchingViewPreviewData.longTitle].map { WatchingModel.Row(archive: $0, state: .available) },
        failure: nil, settingsSummary: "Video + chat · Best available · Medium chat · Downloads",
        downloadsAutomatically: false),
      WatchingModel.Section(
        login: "quietchannel", displayName: "A Quiet Channel",
        rows: [], failure: nil,
        settingsSummary: "Video · Up to 720p · Archive", downloadsAutomatically: false),
    ],
    isSweeping: false, demotions: [:], selection: .constant(nil),
    onAdd: { _, _ in }, onIgnore: { _, _ in }, onEdit: { _ in }, onStopWatching: { _ in },
    stopWatchingFailure: nil, markSeenFailure: nil)
  .frame(width: 480, height: 420)
}

#Preview("Stop Watching failed") {
  WatchingView(
    sections: [
      WatchingModel.Section(
        login: "leighxp", displayName: "LeighXP",
        rows: [WatchingViewPreviewData.normal].map { WatchingModel.Row(archive: $0, state: .available) }, failure: nil,
        settingsSummary: "Video + chat · Best available · Medium chat · Downloads",
        downloadsAutomatically: false),
    ],
    isSweeping: false, demotions: [:], selection: .constant(nil),
    onAdd: { _, _ in }, onIgnore: { _, _ in }, onEdit: { _ in }, onStopWatching: { _ in },
    stopWatchingFailure: "Oxbow could not read the watch list, so LeighXP was not stopped.",
    markSeenFailure: nil)
  .frame(width: 480, height: 420)
}

#Preview("Ignore or Add failed") {
  WatchingView(
    sections: [
      WatchingModel.Section(
        login: "leighxp", displayName: "LeighXP",
        rows: [WatchingViewPreviewData.normal].map { WatchingModel.Row(archive: $0, state: .available) }, failure: nil,
        settingsSummary: "Video + chat · Best available · Medium chat · Downloads",
        downloadsAutomatically: false),
    ],
    isSweeping: false, demotions: [:], selection: .constant(nil),
    onAdd: { _, _ in }, onIgnore: { _, _ in }, onEdit: { _ in }, onStopWatching: { _ in },
    stopWatchingFailure: nil,
    markSeenFailure: "Oxbow could not read the watch list: the file could not be read.")
  .frame(width: 480, height: 420)
}

#Preview("One channel failed") {
  WatchingView(
    sections: [
      WatchingModel.Section(
        login: "leighxp", displayName: "LeighXP",
        rows: [WatchingViewPreviewData.normal].map { WatchingModel.Row(archive: $0, state: .available) }, failure: nil,
        settingsSummary: "Video + chat · Best available · Medium chat · Downloads",
        downloadsAutomatically: false),
      WatchingModel.Section(
        login: "brokenchannel", displayName: "A Broken Channel",
        rows: [],
        failure: "The response did not include the expected video list.",
        settingsSummary: "Video · Up to 1080p · Downloads", downloadsAutomatically: false),
    ],
    isSweeping: false, demotions: [:], selection: .constant(nil),
    onAdd: { _, _ in }, onIgnore: { _, _ in }, onEdit: { _ in }, onStopWatching: { _ in },
    stopWatchingFailure: nil, markSeenFailure: nil)
  .frame(width: 480, height: 420)
}

// A watched channel without findings still shows its settings.
#Preview("Channel with no findings") {
  WatchingView(
    sections: [
      WatchingModel.Section(
        login: "quietchannel", displayName: "A Quiet Channel",
        rows: [], failure: nil,
        settingsSummary: "Video + chat · Best available · Small chat · Downloads",
        downloadsAutomatically: false),
    ],
    isSweeping: false, demotions: [:], selection: .constant(nil),
    onAdd: { _, _ in }, onIgnore: { _, _ in }, onEdit: { _ in }, onStopWatching: { _ in },
    stopWatchingFailure: nil, markSeenFailure: nil)
  .frame(width: 480, height: 420)
}

#Preview("One channel downloads automatically") {
  WatchingView(
    sections: [
      WatchingModel.Section(
        login: "leighxp", displayName: "LeighXP",
        rows: [WatchingViewPreviewData.normal].map { WatchingModel.Row(archive: $0, state: .available) }, failure: nil,
        settingsSummary: "Video + chat · Best available · Medium chat · Downloads",
        downloadsAutomatically: true),
      WatchingModel.Section(
        login: "quietchannel", displayName: "A Quiet Channel",
        rows: [], failure: nil,
        settingsSummary: "Video · Up to 720p · Archive", downloadsAutomatically: false),
    ],
    isSweeping: false, demotions: [:], selection: .constant(nil),
    onAdd: { _, _ in }, onIgnore: { _, _ in }, onEdit: { _ in }, onStopWatching: { _ in },
    stopWatchingFailure: nil, markSeenFailure: nil)
  .frame(width: 480, height: 420)
}

// Verify demotion preserves findings and changes the automatic indicator.
#Preview("Channel demoted, below floor") {
  WatchingView(
    sections: [
      WatchingModel.Section(
        login: "leighxp", displayName: "LeighXP",
        rows: [WatchingViewPreviewData.normal, WatchingViewPreviewData.longTitle].map { WatchingModel.Row(archive: $0, state: .available) },
        failure: nil, settingsSummary: "Video + chat · Best available · Medium chat · Archive",
        downloadsAutomatically: true),
      WatchingModel.Section(
        login: "quietchannel", displayName: "A Quiet Channel",
        rows: [], failure: nil,
        settingsSummary: "Video · Up to 720p · Downloads", downloadsAutomatically: false),
    ],
    isSweeping: false,
    demotions: ["leighxp": .belowFloor(needed: 2_600_000_000, available: 12_000_000_000, floor: 49_000_000_000)],
    selection: .constant(nil),
    onAdd: { _, _ in }, onIgnore: { _, _ in }, onEdit: { _ in }, onStopWatching: { _ in },
    stopWatchingFailure: nil, markSeenFailure: nil)
  .frame(width: 480, height: 420)
}

#Preview("Channel demoted, destination unreachable") {
  WatchingView(
    sections: [
      WatchingModel.Section(
        login: "leighxp", displayName: "LeighXP",
        rows: [WatchingViewPreviewData.normal].map { WatchingModel.Row(archive: $0, state: .available) }, failure: nil,
        settingsSummary: "Video + chat · Best available · Medium chat · Archive",
        downloadsAutomatically: true),
    ],
    isSweeping: false,
    demotions: ["leighxp": .destinationUnreachable("/Volumes/Archive")],
    selection: .constant(nil),
    onAdd: { _, _ in }, onIgnore: { _, _ in }, onEdit: { _ in }, onStopWatching: { _ in },
    stopWatchingFailure: nil, markSeenFailure: nil)
  .frame(width: 480, height: 420)
}

#Preview("No channels watched") {
  WatchingView(
    sections: [], isSweeping: false, demotions: [:], selection: .constant(nil),
    onAdd: { _, _ in }, onIgnore: { _, _ in }, onEdit: { _ in }, onStopWatching: { _ in },
    stopWatchingFailure: nil, markSeenFailure: nil)
    .frame(width: 480, height: 420)
}

#Preview("Checking, first sweep") {
  // Before the first sweep lands, do not imply no channels are watched.
  WatchingView(
    sections: [], isSweeping: true, demotions: [:], selection: .constant(nil),
    onAdd: { _, _ in }, onIgnore: { _, _ in }, onEdit: { _ in }, onStopWatching: { _ in },
    stopWatchingFailure: nil, markSeenFailure: nil)
    .frame(width: 480, height: 420)
}

/// Anchor dates to the real clock because WatchingView does not inject now; ArchiveRow's
/// fixed-date fixtures would drift here.
private enum WatchingViewPreviewData {
  static let normal = ChannelArchive(
    id: "1", title: "Indie horror night",
    duration: .seconds(3 * 3600 + 24 * 60),
    publishedAt: Date().addingTimeInterval(-12 * 86400),
    status: .recorded, thumbnailURL: nil)

  static let longTitle = ChannelArchive(
    id: "2",
    title: "LeighXP - 2026-08-12 - indie horror + something else later?? "
      + "also chatting about the new patch notes and taking questions",
    duration: .seconds(5 * 3600),
    publishedAt: Date(),
    status: .recorded, thumbnailURL: nil)
}
