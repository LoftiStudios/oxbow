import OxbowKit
import SwiftUI

/// One archive: what it is, when it was published, what state it is in, and
/// what can be done about it.
///
/// **The age comes from `RelativeDay`, never a countdown.** There is no
/// `expiresAt` on a Twitch video and retention runs from six weeks to nine
/// months with nothing predicting which (`docs/design/channel-watching.md`
/// §7), so a countdown here would be a number this row invented.
///
/// **The row never decides its own state.** `ArchiveRowState` does, from
/// inputs resolved before the view is built — see that type. This switches
/// on the answer and nothing more.
struct ArchiveRow: View {
  let row: WatchingModel.Row
  let store: ImageStore?
  var now: Date = .now
  let onAdd: () -> Void
  let onIgnore: () -> Void
  let onAddWithOptions: () -> Void
  let onReveal: (URL) -> Void

  var body: some View {
    // The menu is attached only when it has something in it. A `.contextMenu`
    // whose builder produces no items still opens — an empty sliver under the
    // pointer — which is a worse answer to a right-click than no menu, and
    // was what `.queued`, `.running` and `.unverifiable` gave.
    //
    // The cost of branching here rather than inside one `.contextMenu` is
    // that a row crossing between these arms — Add, most visibly — is a new
    // view to SwiftUI, so `ArchiveThumbnail`'s image reloads from the store
    // for a frame. Paid knowingly: it is one frame of a placeholder on a
    // warm disk read, against a menu that opens onto nothing every time.
    if row.state.isFetchable {
      content.contextMenu {
        Button("Add…", action: onAddWithOptions)
        Button("Ignore", action: onIgnore)
      }
    } else if case .downloaded(let url) = row.state {
      content.contextMenu {
        Button("Show in Finder") { onReveal(url) }
      }
    } else {
      content
    }
  }

  private var content: some View {
    HStack(alignment: .center, spacing: 10) {
      ArchiveThumbnail(url: row.archive.thumbnailURL, store: store)

      VStack(alignment: .leading, spacing: 2) {
        Text(row.archive.title)
          .lineLimit(2)
        Text(RelativeDay.phrase(for: row.archive.publishedAt, now: now))
          .font(.caption)
          .foregroundStyle(.secondary)
          // Higher than the title's default: when the row is squeezed the
          // title truncates and this line stays whole, because this is what
          // a person triages by.
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
        .help("Still broadcasting. Oxbow waits until it ends — what exists now is half a video.")
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
    case .missing:
      Button("Add", action: onAdd)
        .buttonStyle(.bordered)
        .controlSize(.small)
        // Not the prominent style: this is a second copy of something you
        // already had and chose to delete, so it is offered rather than
        // urged.
        .help("Downloaded before, and the file is not there now. Download it again.")
    case .unverifiable(let volume):
      Label(volume, systemImage: "externaldrive.badge.questionmark")
        .labelStyle(.iconOnly)
        .foregroundStyle(.secondary)
        .help("\(volume) is disconnected, so Oxbow cannot tell whether this is still downloaded.")
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
      onAdd: {}, onIgnore: {}, onAddWithOptions: {}, onReveal: { _ in })
  }
  .frame(width: 420, height: 100)
}

#Preview("Live") {
  List {
    ArchiveRow(
      row: WatchingModel.Row(archive: ArchiveRowPreviewData.normal, state: .live),
      store: nil, now: ArchiveRowPreviewData.now,
      onAdd: {}, onIgnore: {}, onAddWithOptions: {}, onReveal: { _ in })
  }
  .frame(width: 420, height: 100)
}

#Preview("Queued") {
  List {
    ArchiveRow(
      row: WatchingModel.Row(archive: ArchiveRowPreviewData.normal, state: .queued),
      store: nil, now: ArchiveRowPreviewData.now,
      onAdd: {}, onIgnore: {}, onAddWithOptions: {}, onReveal: { _ in })
  }
  .frame(width: 420, height: 100)
}

#Preview("Downloading") {
  List {
    ArchiveRow(
      row: WatchingModel.Row(archive: ArchiveRowPreviewData.normal, state: .running),
      store: nil, now: ArchiveRowPreviewData.now,
      onAdd: {}, onIgnore: {}, onAddWithOptions: {}, onReveal: { _ in })
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
      onAdd: {}, onIgnore: {}, onAddWithOptions: {}, onReveal: { _ in })
  }
  .frame(width: 420, height: 100)
}

#Preview("Missing") {
  List {
    ArchiveRow(
      row: WatchingModel.Row(archive: ArchiveRowPreviewData.normal, state: .missing),
      store: nil, now: ArchiveRowPreviewData.now,
      onAdd: {}, onIgnore: {}, onAddWithOptions: {}, onReveal: { _ in })
  }
  .frame(width: 420, height: 100)
}

#Preview("Unverifiable") {
  List {
    ArchiveRow(
      row: WatchingModel.Row(
        archive: ArchiveRowPreviewData.normal, state: .unverifiable(volumeName: "Helios")),
      store: nil, now: ArchiveRowPreviewData.now,
      onAdd: {}, onIgnore: {}, onAddWithOptions: {}, onReveal: { _ in })
  }
  .frame(width: 420, height: 100)
}

#Preview("Failed") {
  List {
    ArchiveRow(
      row: WatchingModel.Row(archive: ArchiveRowPreviewData.normal, state: .failed),
      store: nil, now: ArchiveRowPreviewData.now,
      onAdd: {}, onIgnore: {}, onAddWithOptions: {}, onReveal: { _ in })
  }
  .frame(width: 420, height: 100)
}

/// Fixtures for the previews above.
///
/// Not `WatchingView`'s: that view defines its own `WatchingViewPreviewData`
/// and explains at length why it must — see the comment there.
private enum ArchiveRowPreviewData {
  static let now = Date(timeIntervalSince1970: 1_754_000_000)

  static let normal = ChannelArchive(
    id: "1", title: "Indie horror night",
    duration: .seconds(3 * 3600 + 24 * 60),
    publishedAt: now.addingTimeInterval(-12 * 86400),
    status: .recorded, thumbnailURL: nil)
}
