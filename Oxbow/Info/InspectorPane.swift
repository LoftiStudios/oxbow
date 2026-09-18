import AppKit
import SwiftUI
import OxbowKit

/// Selection-following inspector; see docs/design/inspector.md. Shares VideoCard and
/// VideoInfoLoad with Get Info; detailed steps and delivered files remain in that window.
struct InspectorPane: View {
  let subject: InspectorSubject
  let controller: QueueController?
  /// Stored metadata fallback; unavailable until a support directory resolves.
  var record: VideoRecordStore? = nil
  /// Shared image cache; the stack initiates no additional fetching.
  var imageStore: ImageStore? = nil

  @State private var metadata: VideoInfoLoad = .loading

  /// The delivered files' size on disk, measured off the main path in the same
  /// task as the metadata. Nil until measured, and nil when it cannot be.
  @State private var deliveredBytes: Int64?

  @Environment(\.colorScheme) private var colorScheme

  private var isMultiple: Bool {
    if case .many = subject { return true }
    return false
  }

  var body: some View {
    ZStack(alignment: .top) {
      switch subject {
      case .nothing:
        empty
          .transition(.opacity)
          .zIndex(0)
      case .one(let target):
        single(target)
          .transition(.opacity)
          .zIndex(1)
      case .many(let many):
        multiple(many)
          .transition(.opacity)
          .zIndex(2)
      }
    }
    // Keep the outgoing pane underneath while the new one fades in. Key this
    // only to crossing the single/stack boundary: count and progress updates
    // should not fade the whole inspector or override the cards' own spring.
    .animation(.easeInOut(duration: 0.22), value: isMultiple)
    // Open at 420pt; allow narrowing to the 260pt floor included in QueueView's minimum width.
    .inspectorColumnWidth(min: 260, ideal: 420, max: 420)
  }

  /// No selection shows a placeholder, not channel details or queue totals.
  private var empty: some View {
    ContentUnavailableView {
      Label("Nothing selected", systemImage: "sidebar.right")
    } description: {
      Text("Select a download or an archive to see its details.")
    }
  }

  @ViewBuilder
  private func single(_ target: InfoTarget) -> some View {
    let job = job(for: target)
    VStack(spacing: 0) {
      Form {
          // Share the full VideoCard with Get Info; layout fixes belong in that component.
        Section {
          switch metadata {
          case .loading:
            VideoCard(.loading)
          case .loaded(let info):
            VideoCard(info: info)
          case .unavailable:
            VideoCard(.unavailable(title: job?.title ?? "Video"))
          }

        }

        if let job {
          facts(JobInfo(job: job))
        } else {
          Section {
            Text("Not downloaded").foregroundStyle(.secondary)
          }
        }
      }
      .formStyle(.grouped)

      if let job {
        Divider()
        // Keep the shared destination footer visible outside the scroll area.
        SavedToFooter(info: JobInfo(job: job))
      }
    }
    // Keyed on the identifier, matching `JobInfoWindow`'s own `.task(id:)`,
    // so moving between two rows for the same video does not refetch.
    .task(id: VideoInfoLoad.identifier(for: target, jobs: controller?.jobs ?? [])) {
      // Clear the previous video's card before awaiting the new subject's metadata.
      metadata = .loading
      deliveredBytes = nil
      guard let controller else { return }
      metadata = await VideoInfoLoad.resolve(
        identifier: VideoInfoLoad.identifier(for: target, jobs: controller.jobs),
        controller: controller, record: record,
        // Prefer recorded metadata while navigating selections to avoid an info subprocess per
        // row.
        freshness: .remembered)
      deliveredBytes = Self.sizeOnDisk(of: job?.deliveredFiles ?? [])
    }
  }

  /// Use JobInfo and JobStatusValue to keep these facts consistent with Get Info.
  private func facts(_ info: JobInfo) -> some View {
    Section("Download") {
      LabeledContent("Status") { JobStatusValue(status: info.job.status) }
      LabeledContent("Outputs", value: info.outputs.joined(separator: ", "))
      if !info.quality.isEmpty {
        LabeledContent("Quality", value: info.quality)
      }
      LabeledContent("Trim", value: info.trim)
      // Hide the total if any delivered file could not be measured.
      if let deliveredBytes {
        LabeledContent(
          "Filesize", value: deliveredBytes.formatted(.byteCount(style: .file)))
      }
    }
  }

  /// Total delivered size, or nil if any file cannot be read. Never return a partial sum.
  private static func sizeOnDisk(of files: [URL]) -> Int64? {
    guard !files.isEmpty else { return nil }
    var total = Int64(0)
    for file in files {
      guard let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize
      else { return nil }
      total += Int64(size)
    }
    return total
  }

  @ViewBuilder
  private func multiple(_ many: MultiSelection) -> some View {
    Form {
      Section {
        if !many.cards.isEmpty {
          SelectionStack(cards: many.cards, store: imageStore)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        VStack(alignment: .leading, spacing: 2) {
          Text("\(many.count) downloads selected")
            .font(.headline)
          if !many.channels.isEmpty {
            Text(many.channels.joined(separator: ", "))
              .font(.subheadline)
              .foregroundStyle(.secondary)
              .lineLimit(1)
              .truncationMode(.tail)
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
      }

      Section("Download") {
        LabeledContent("Status") { statusValue(many) }
        // Only show an estimate when every selected job can be priced. Label it approximate,
        // unlike measured Filesize.
        if let bytes = many.estimatedBytes {
          LabeledContent(
            "Filesize", value: "about \(bytes.formatted(.byteCount(style: .file)))")
        }
      }
    }
    .formStyle(.grouped)
  }

  /// Stack mixed statuses vertically to fit a narrow inspector; order the most serious first.
  @ViewBuilder
  private func statusValue(_ many: MultiSelection) -> some View {
    let parts: [(JobStatus, Int)] = [
      (.failed, many.failed), (.cancelled, many.cancelled),
      (.running, many.running), (.queued, many.queued), (.done, many.done),
    ].filter { $0.1 > 0 }

    VStack(alignment: .trailing, spacing: 4) {
      ForEach(Array(parts.enumerated()), id: \.offset) { _, part in
        let icon = JobPresentation.icon(for: part.0)
        HStack(spacing: QueueMetrics.iconSpacing) {
          Image(systemName: icon.name)
            .foregroundStyle(icon.tone.color(for: colorScheme))
            .accessibilityHidden(true)
          Text(parts.count == 1
            ? "\(many.count) \(JobPresentation.accessibilityStatus(of: part.0).capitalized)"
            : "\(part.1) \(JobPresentation.accessibilityStatus(of: part.0))")
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
        }
      }
    }
    .accessibilityElement(children: .combine)
  }

  /// Join video targets to queue jobs through mediaIdentifier.
  private func job(for target: InfoTarget) -> Job? {
    guard let controller else { return nil }
    switch target {
    case .job(let id):
      return controller.jobs.first { $0.id == id }
    case .video(let media):
      return controller.jobs.first { $0.mediaIdentifier == media }
    }
  }

}

// Preview the default width and the supported 260pt minimum.
#Preview("Nothing selected") {
  InspectorPane(subject: .nothing, controller: nil)
    .frame(width: 420, height: 420)
}

// Regression preview: four statuses must fit at the minimum column width.
#Preview("Several selected, four statuses") {
  InspectorPane(
    subject: .many(MultiSelection(
      count: 10, queued: 0, running: 1, done: 7, failed: 1, cancelled: 1,
      estimatedBytes: 4_200_000_000,
      cards: [], channels: ["LeighXP", "WheelyF", "lilbadsnacks"])),
    controller: nil)
    .frame(width: 260, height: 460)
}

#Preview("Several selected, priced") {
  InspectorPane(
    subject: .many(MultiSelection(
      count: 5, queued: 3, failed: 2, estimatedBytes: 12_400_000_000)),
    controller: nil)
    .frame(width: 420, height: 420)
}

#Preview("Several selected, unpriceable") {
  InspectorPane(
    subject: .many(MultiSelection(count: 5, queued: 3, failed: 2)),
    controller: nil)
    .frame(width: 420, height: 420)
}

// Without a controller, previews show the unavailable-metadata fallback.
#Preview("One selected, not downloaded") {
  InspectorPane(subject: .one(.video("2844787557")), controller: nil)
    .frame(width: 420, height: 420)
}
