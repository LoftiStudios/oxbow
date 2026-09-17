import AppKit
import SwiftUI
import OxbowKit

/// Shared Edit and Stop Watching actions for card and sidebar menus. Keep the visible menu
/// button for discoverability. Stopping a watch preserves delivered files and asks for no
/// confirmation.
struct ChannelActionsMenu: View {
  let displayName: String
  let onEdit: () -> Void
  let onStopWatching: () -> Void

  var body: some View {
    Button {
      onEdit()
    } label: {
      Label("Edit\u{2026}", systemImage: "pencil")
    }
    .help("Change \(displayName)'s frozen settings.")

    Button {
      onStopWatching()
    } label: {
      Label("Stop Watching", systemImage: "eye.slash")
    }
    .help("""
      Stops watching \(displayName). Files already downloaded are not deleted.
      """)
  }
}

struct ChannelCard: View {
  let section: WatchingModel.Section
  let imageStore: ImageStore?
  /// The current sweep's reason for pausing this channel's automatic downloads.
  let demotionReason: AutoDownloadPolicy.Reason?
  let onEdit: () -> Void
  let onStopWatching: () -> Void

  /// Report the first disconnected volume from recorded-file rows or the destination probe.
  /// Rows alone miss offline destinations with no recorded delivery claim.
  private var disconnectedVolume: String? {
    Self.disconnectedVolume(in: section.rows) ?? section.disconnectedDestination
  }

  static func disconnectedVolume(in rows: [WatchingModel.Row]) -> String? {
    for row in rows {
      if case .unverifiable(let volumeName) = row.state { return volumeName }
    }
    return nil
  }

  private var actions: some View {
    ChannelActionsMenu(
      displayName: section.displayName,
      onEdit: onEdit,
      onStopWatching: onStopWatching)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(alignment: .center, spacing: 14) {
        ChannelAvatar(url: section.avatarURL, store: imageStore, size: 88)
        VStack(alignment: .leading, spacing: 2) {
          HStack(spacing: 6) {
            Text(section.displayName)
              .font(.title)
              .fontWeight(.semibold)
            // Show the automatic mark only when enabled.
            if section.downloadsAutomatically {
              if let demotionReason {
                // Distinguish paused downloads by icon and colour, not only tooltip.
                Label("Downloads paused", systemImage: "bolt.slash.fill")
                  .labelStyle(.iconOnly)
                  .foregroundStyle(.orange)
                  .help(demotionReason.sentence)
              } else {
                Label("Downloads automatically", systemImage: "bolt.fill")
                  .labelStyle(.iconOnly)
                  .foregroundStyle(.blue)
                  .help("""
                    Set to download automatically. New archives from this \
                    channel are queued and downloaded on their own, without \
                    waiting for Add.
                    """)
              }
            }
            Spacer(minLength: 0)
          }
          if !section.settingsSummary.isEmpty {
            Text(section.settingsSummary)
              .font(.subheadline)
              .foregroundStyle(.secondary)
          }
        }
        // Keep a visible route to actions also offered by right-click.
        Menu {
          actions
        } label: {
          Label("Channel actions", systemImage: "ellipsis")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .labelStyle(.iconOnly)
        .fixedSize()
        .accessibilityLabel("Actions for \(section.displayName)")
      }
      if let disconnectedVolume {
        disconnectedVolumeNotice(disconnectedVolume)
      }
    }
    .padding(.vertical, 8)
    .textCase(nil)
    .contextMenu { actions }
  }

  /// Separate unavailable existing files from paused future downloads with a distinct icon and
  /// message.
  private func disconnectedVolumeNotice(_ volume: String) -> some View {
    Label {
      // Mention paused downloading only for automatic watches.
      Text(section.downloadsAutomatically
        ? "\(volume) is disconnected. Oxbow can't tell whether downloads on it are still there, and new ones are paused until it's back."
        : "\(volume) is disconnected. Oxbow can't tell whether downloads on it are still there.")
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    } icon: {
      Image(systemName: "externaldrive.badge.questionmark")
        .foregroundStyle(.secondary)
    }
    .accessibilityElement(children: .combine)
  }
}

#Preview("Avatar, downloads automatically") {
  List {
    Section {
      Text("Rows go here")
    } header: {
      ChannelCard(
        section: WatchingModel.Section(
          login: "leighxp", displayName: "LeighXP",
          avatarURL: ChannelCardPreviewData.avatarURL,
          rows: [], failure: nil,
          settingsSummary: "Video + chat · Best available · Medium chat · Downloads",
          downloadsAutomatically: true),
        imageStore: nil, demotionReason: nil,
        onEdit: {}, onStopWatching: {})
    }
  }
  .frame(width: 480, height: 220)
}

#Preview("No avatar") {
  List {
    Section {
      Text("Rows go here")
    } header: {
      ChannelCard(
        section: WatchingModel.Section(
          login: "quietchannel", displayName: "A Quiet Channel",
          rows: [], failure: nil,
          settingsSummary: "Video · Up to 720p · Archive",
          downloadsAutomatically: false),
        imageStore: nil, demotionReason: nil,
        onEdit: {}, onStopWatching: {})
    }
  }
  .frame(width: 480, height: 220)
}

#Preview("Demoted, below floor") {
  List {
    Section {
      Text("Rows go here")
    } header: {
      ChannelCard(
        section: WatchingModel.Section(
          login: "leighxp", displayName: "LeighXP",
          rows: [], failure: nil,
          settingsSummary: "Video + chat · Best available · Medium chat · Archive",
          downloadsAutomatically: true),
        imageStore: nil,
        demotionReason: .belowFloor(needed: 2_600_000_000, available: 12_000_000_000, floor: 49_000_000_000),
        onEdit: {}, onStopWatching: {})
    }
  }
  .frame(width: 480, height: 220)
}

#Preview("Disconnected volume") {
  List {
    Section {
      Text("Rows go here")
    } header: {
      ChannelCard(
        section: WatchingModel.Section(
          login: "leighxp", displayName: "LeighXP",
          rows: [
            WatchingModel.Row(
              archive: ChannelCardPreviewData.normal,
              state: .unverifiable(volumeName: "Helios")),
          ],
          failure: nil,
          settingsSummary: "Video + chat · Best available · Medium chat · Downloads",
          downloadsAutomatically: false),
        imageStore: nil, demotionReason: nil,
        onEdit: {}, onStopWatching: {})
    }
  }
  .frame(width: 480, height: 260)
}

/// Use current-date fixtures because this card does not inject now into its children.
private enum ChannelCardPreviewData {
  static let avatarURL = URL(string: "https://static-cdn.jtvnw.net/preview.jpg")!

  static let normal = ChannelArchive(
    id: "1", title: "Indie horror night",
    duration: .seconds(3 * 3600 + 24 * 60),
    publishedAt: Date().addingTimeInterval(-12 * 86400),
    status: .recorded, thumbnailURL: nil)
}
