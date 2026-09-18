import OxbowKit
import SwiftUI

/// Render ArchiveRowState without deriving policy in the view. Show age, not an invented expiry
/// countdown; Twitch provides no reliable expiry date.
struct ArchiveRow: View {
  let row: WatchingModel.Row
  let store: ImageStore?
  var now: Date = .now
  let onAdd: () -> Void
  let onIgnore: () -> Void
  let onAddWithOptions: () -> Void
  let onReveal: (URL) -> Void

  /// Get Info remains available in every archive state.
  let onShowInfo: () -> Void

  var body: some View {
    // Attach menus by state; avoid an empty context menu on non-fetchable rows.
    if row.state.isFetchable {
      content.contextMenu {
        Button("Add…", action: onAddWithOptions)
        Button("Ignore", action: onIgnore)
        Divider()
        Button("Get Info", action: onShowInfo)
      }
    } else if case .downloaded(let url) = row.state {
      content.contextMenu {
        Button("Show in Finder") { onReveal(url) }
        Divider()
        Button("Get Info", action: onShowInfo)
      }
    } else {
      content.contextMenu {
        Button("Get Info", action: onShowInfo)
      }
    }
  }

  private var content: some View {
    HStack(alignment: .center, spacing: 10) {
      // Use category box art in the row; the archive thumbnail remains available separately.
      ArchiveThumbnail(
        url: row.archive.categoryArtURL, store: store,
        label: row.archive.categoryName)

      VStack(alignment: .leading, spacing: 2) {
        Text(row.archive.title)
          .lineLimit(2)
        Text("\(RelativeDay.phrase(for: row.archive.publishedAt, now: now, includingVerb: false)) · \(VideoLength.timecode(row.archive.duration))")
          .font(.caption)
          .foregroundStyle(.secondary)
          // Preserve age and duration before the title when space is tight.
          .layoutPriority(1)
      }

      Spacer(minLength: 8)
      badge
    }
    .padding(.vertical, 4)
  }

  @ViewBuilder
  private var badge: some View {
    switch row.state {
    case .available:
      Button("Add", action: onAdd)
        .buttonStyle(.borderedProminent)
        .controlSize(.small)
        .help("Download this now, using this channel's settings.")
    case .live:
      Label("Live", systemImage: "dot.radiowaves.left.and.right")
        .labelStyle(.titleAndIcon)
        .font(.caption)
        .foregroundStyle(.secondary)
        .help("Not downloadable right now, and Oxbow will not fetch it on its own.")
    case .expired:
      // Expired, undownloaded archives have no Add action; the row records what was missed.
      Text("No longer on Twitch")
        .font(.caption)
        .foregroundStyle(.secondary)
        .help("Twitch no longer has this, and Oxbow has no copy of it.")
    case .queued:
      Text("In queue").font(.caption).foregroundStyle(.secondary)
    case .running:
      Text("Downloading").font(.caption).foregroundStyle(.secondary)
    case .downloaded(let url):
      Button {
        onReveal(url)
      } label: {
        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
      }
      .buttonStyle(.plain)
      .help("Downloaded. Click to show it in Finder.")
      // Icon-only controls need accessibility labels; help text alone is insufficient.
      .accessibilityLabel("Downloaded. Show in Finder")
    case .missing:
      Button("Add", action: onAdd)
        .buttonStyle(.bordered)
        .controlSize(.small)
        .help("Downloaded before, and the file is not there now. Download it again.")
    case .unverifiable(let volume):
      Label(volume, systemImage: "externaldrive.badge.questionmark")
        .labelStyle(.iconOnly)
        .foregroundStyle(.secondary)
        .help("\(volume) is disconnected, so Oxbow cannot tell whether this is still downloaded.")
        // Include the disconnected volume name in the accessibility label.
        .accessibilityLabel("\(volume) is disconnected. Oxbow cannot tell whether this is still downloaded")
    case .failed:
      Button("Retry", action: onAdd)
        .buttonStyle(.bordered)
        .controlSize(.small)
        .help("The download failed. Try again.")
    }
  }
}

#Preview("Available") {
  List {
    ArchiveRow(
      row: WatchingModel.Row(archive: ArchiveRowPreviewData.normal, state: .available),
      store: nil, now: ArchiveRowPreviewData.now,
      onAdd: {}, onIgnore: {}, onAddWithOptions: {}, onReveal: { _ in },
      onShowInfo: {})
  }
  .frame(width: 420, height: 100)
}

#Preview("Live") {
  List {
    ArchiveRow(
      row: WatchingModel.Row(archive: ArchiveRowPreviewData.normal, state: .live),
      store: nil, now: ArchiveRowPreviewData.now,
      onAdd: {}, onIgnore: {}, onAddWithOptions: {}, onReveal: { _ in },
      onShowInfo: {})
  }
  .frame(width: 420, height: 100)
}

#Preview("Queued") {
  List {
    ArchiveRow(
      row: WatchingModel.Row(archive: ArchiveRowPreviewData.normal, state: .queued),
      store: nil, now: ArchiveRowPreviewData.now,
      onAdd: {}, onIgnore: {}, onAddWithOptions: {}, onReveal: { _ in },
      onShowInfo: {})
  }
  .frame(width: 420, height: 100)
}

#Preview("Downloading") {
  List {
    ArchiveRow(
      row: WatchingModel.Row(archive: ArchiveRowPreviewData.normal, state: .running),
      store: nil, now: ArchiveRowPreviewData.now,
      onAdd: {}, onIgnore: {}, onAddWithOptions: {}, onReveal: { _ in },
      onShowInfo: {})
  }
  .frame(width: 420, height: 100)
}

#Preview("Downloaded") {
  List {
    ArchiveRow(
      row: WatchingModel.Row(
        archive: ArchiveRowPreviewData.normal,
        state: .downloaded(URL(fileURLWithPath: "/Users/me/Movies/Indie horror night.mp4"))),
      store: nil, now: ArchiveRowPreviewData.now,
      onAdd: {}, onIgnore: {}, onAddWithOptions: {}, onReveal: { _ in },
      onShowInfo: {})
  }
  .frame(width: 420, height: 100)
}

#Preview("Missing") {
  List {
    ArchiveRow(
      row: WatchingModel.Row(archive: ArchiveRowPreviewData.normal, state: .missing),
      store: nil, now: ArchiveRowPreviewData.now,
      onAdd: {}, onIgnore: {}, onAddWithOptions: {}, onReveal: { _ in },
      onShowInfo: {})
  }
  .frame(width: 420, height: 100)
}

#Preview("Unverifiable") {
  List {
    ArchiveRow(
      row: WatchingModel.Row(
        archive: ArchiveRowPreviewData.normal, state: .unverifiable(volumeName: "Helios")),
      store: nil, now: ArchiveRowPreviewData.now,
      onAdd: {}, onIgnore: {}, onAddWithOptions: {}, onReveal: { _ in },
      onShowInfo: {})
  }
  .frame(width: 420, height: 100)
}

#Preview("Failed") {
  List {
    ArchiveRow(
      row: WatchingModel.Row(archive: ArchiveRowPreviewData.normal, state: .failed),
      store: nil, now: ArchiveRowPreviewData.now,
      onAdd: {}, onIgnore: {}, onAddWithOptions: {}, onReveal: { _ in },
      onShowInfo: {})
  }
  .frame(width: 420, height: 100)
}

private enum ArchiveRowPreviewData {
  static let now = Date(timeIntervalSince1970: 1_754_000_000)

  static let normal = ChannelArchive(
    id: "1", title: "Indie horror night",
    duration: .seconds(3 * 3600 + 24 * 60),
    publishedAt: now.addingTimeInterval(-12 * 86400),
    status: .recorded, thumbnailURL: nil)
}
