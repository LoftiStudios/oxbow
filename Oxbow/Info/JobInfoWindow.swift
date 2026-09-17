import AppKit
import SwiftUI
import OxbowKit

/// Read-only download details, updated from the live queue rather than captured when the window
/// opens.
struct JobInfoWindow: View {
  let target: InfoTarget
  let controller: QueueController

  /// Stored metadata fallback; omitted without a support directory or during hosted tests.
  let record: VideoRecordStore?

  @State private var metadata: VideoInfoLoad = .loading

  /// A video can have no queue job. For multiple matching jobs, use ArchiveRowState's
  /// preference: unfinished, finished, then the remainder.
  private var job: Job? {
    switch target {
    case .job(let id):
      return controller.jobs.first { $0.id == id }
    case .video(let identifier):
      let mine = controller.jobs.filter { $0.mediaIdentifier == identifier }
      return mine.first { $0.status.isUnfinished }
        ?? mine.first { $0.status == .done }
        ?? mine.first
    }
  }

  /// The video this window is about, for the metadata fetch and the record
  /// lookup behind it.
  private var videoIdentifier: String? {
    VideoInfoLoad.identifier(for: target, jobs: controller.jobs)
  }

  var body: some View {
    Group {
      if let job {
        content(for: job, info: JobInfo(job: job))
      } else if case .video = target {
        videoOnlyContent
      } else {
        ContentUnavailableView(
          "Download removed", systemImage: "tray",
          description: Text("This download is no longer in the queue."))
      }
    }
    .frame(minWidth: 420, minHeight: 360)
    .navigationTitle(job?.title ?? cardTitle ?? "Video")
    .task(id: videoIdentifier) {
      await loadMetadata()
    }
  }

  /// The title the card resolved, for a window with no job to borrow one from.
  private var cardTitle: String? {
    if case .loaded(let info) = metadata { return info.title }
    return nil
  }

  /// Use the same video card when no job exists; omit download-specific sections.
  private var videoOnlyContent: some View {
    Form {
      Section {
        switch metadata {
        case .loading: VideoCard(.loading)
        case .loaded(let info): VideoCard(info: info)
        case .unavailable: VideoCard(.unavailable(title: "Video"))
        }
        if case .video(let identifier) = target,
           let source = URL(string: "https://www.twitch.tv/videos/\(identifier)")
        {
          LabeledContent("Link") {
            Text(source.absoluteString)
              .textSelection(.enabled)
              .lineLimit(1)
              .truncationMode(.middle)
              .help(source.absoluteString)
          }
        }
        LabeledContent("Status") {
          Text("Not downloaded").foregroundStyle(.secondary)
        }
      }
    }
    .formStyle(.grouped)
  }

  private func content(for job: Job, info: JobInfo) -> some View {
    VStack(spacing: 0) {
      Form {
        Section {
          // Reserve the card's space while fetching to prevent a layout jump.
          switch metadata {
          case .loading: VideoCard(.loading)
          case .loaded(let info): VideoCard(info: info)
          case .unavailable: VideoCard(.unavailable(title: job.title))
          }
          if let source = info.sourceURL {
            LabeledContent("Link") {
              Text(source.absoluteString)
                .textSelection(.enabled)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(source.absoluteString)
            }
          }
          LabeledContent("Status") { JobStatusValue(status: job.status) }
        }

        Section("Download") {
          LabeledContent("Outputs", value: info.outputs.joined(separator: ", "))
          if info.video != nil || info.clip != nil {
            LabeledContent("Quality", value: info.quality)
          }
          LabeledContent("Trim", value: info.trim)
        }

        if !info.renderSettings.isEmpty {
          Section("Render") {
            ForEach(info.renderSettings) { setting in
              LabeledContent(setting.label, value: setting.value)
            }
          }
        }

        Section("Steps") {
          ForEach(job.steps) { step in
            StepInfoRow(step: step, log: { await controller.log(for: $0) })
          }
        }

        if !info.deliveredFiles.isEmpty {
          Section("Files") {
            ForEach(info.deliveredFiles, id: \.self) { file in
              LabeledContent(file.lastPathComponent) {
                Button("Show") { NSWorkspace.shared.activateFileViewerSelecting([file]) }
                  .controlSize(.small)
              }
            }
          }
        }
      }
      .formStyle(.grouped)

      Divider()
      SavedToFooter(info: info)
    }
  }

  /// Fetch current metadata with the shared loader and its recorded-data fallback.
  private func loadMetadata() async {
    metadata = await VideoInfoLoad.resolve(
      identifier: videoIdentifier, controller: controller, record: record)
  }

}

/// Shared status label for Get Info and the inspector, using the queue's symbol and tone. Hide
/// the redundant image from VoiceOver.
struct JobStatusValue: View {
  let status: JobStatus

  @Environment(\.colorScheme) private var colorScheme

  var body: some View {
    let icon = JobPresentation.icon(for: status)

    HStack(spacing: QueueMetrics.iconSpacing) {
      Image(systemName: icon.name)
        .foregroundStyle(icon.tone.color(for: colorScheme))
        .accessibilityHidden(true)

      Text(JobPresentation.accessibilityStatus(of: status).capitalized)
    }
  }
}

/// One step, as Get Info shows it: what it is, where it got to, and what the
/// helper said.
private struct StepInfoRow: View {
  let step: Step
  let log: (StepID) async -> String?

  @Environment(\.colorScheme) private var colorScheme

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack(spacing: QueueMetrics.iconSpacing) {
        let icon = JobPresentation.icon(for: step.status)
        Image(systemName: icon.name)
          .foregroundStyle(icon.tone.color(for: colorScheme))
          .frame(width: QueueMetrics.icon, height: QueueMetrics.titleLine)
          .accessibilityHidden(true)

        Text(JobPresentation.label(for: step.kind))
        Spacer(minLength: 8)
        Text(status)
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      VStack(alignment: .leading, spacing: 4) {
        StepDetail(step: step)
        if showsLog {
          StepLogDisclosure(step: step, log: log, failure: failure)
        }
      }
      .padding(.leading, QueueMetrics.contentIndent)
    }
  }

  /// Successful job cleanup removes logs with the workspace; do not offer an empty disclosure.
  private var showsLog: Bool {
    if case .failed = step.status { return true }
    return step.status == .running
  }

  private var failure: StepFailure? {
    if case .failed(let failure) = step.status { return failure }
    return nil
  }

  private var status: String {
    switch step.status {
    case .queued: "Queued"
    case .blocked: "Blocked"
    case .running: "Running"
    case .done: "Done"
    case .failed: "Failed"
    case .cancelled: "Cancelled"
    }
  }
}

#Preview("Finished job") {
  // A controller cannot be stood up without an engine, so this previews the
  // read-only body directly against a fake job.
  Form {
    Section("Download") {
      LabeledContent("Outputs", value: "Video + chat")
      LabeledContent("Quality", value: "1080p60")
      LabeledContent("Trim", value: "Whole video")
    }
    Section("Render") {
      ForEach(JobInfo(job: JobInfoPreviewData.rendered).renderSettings) { setting in
        LabeledContent(setting.label, value: setting.value)
      }
    }
  }
  .formStyle(.grouped)
  .frame(width: 460, height: 520)
}

#Preview("Status row - every state") {
  Form {
    Section {
      ForEach(
        [JobStatus.queued, .running, .done, .failed, .cancelled],
        id: \.self)
      { status in
        LabeledContent("Status") { JobStatusValue(status: status) }
      }
    }
  }
  .formStyle(.grouped)
  .frame(width: 460)
}

enum JobInfoPreviewData {
  /// A composite fixture includes both steps required by renderSettings.
  static let rendered = Job(
    id: JobID(rawValue: UUID()), created: .now, title: "LeighXP - indie horror",
    steps: [
      Step(
        id: StepID(rawValue: UUID()),
        kind: .renderChat(RenderRequest(
          width: 420, height: 1080, framerate: 30, destination: nil)),
        status: .done),
      Step(
        id: StepID(rawValue: UUID()),
        kind: .composite(CompositeRequest(
          framerate: 60, duration: .seconds(600),
          destination: URL(filePath: "/tmp/out.mp4"))),
        status: .done),
    ])
}
