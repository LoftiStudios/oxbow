import AppKit
import SwiftUI
import OxbowKit

/// Get Info for one download: what it was set to, what it is doing, and what
/// it produced.
///
/// **Read-only, and shaped like reading rather than like a disabled form.**
/// It keeps Add Download's sections, labels and order so the two are
/// recognisably the same window, but every value is text. A screen of greyed
/// controls says "broken"; the same information as text says "this is what
/// happened", which is the actual question Get Info answers.
///
/// Live, not a snapshot: it reads the job back out of the controller on every
/// change, so opening it on a running download shows the progress moving and
/// the steps completing rather than a frozen picture of the moment you asked.
struct JobInfoWindow: View {
  let jobID: JobID
  let controller: QueueController

  /// Where the metadata fetch has got to. Three states rather than an
  /// optional, so the card can tell "still coming" from "never arriving" —
  /// and stay the same size in both.
  private enum Metadata {
    case loading
    case loaded(VideoInfo)
    case unavailable
  }

  @State private var metadata: Metadata = .loading

  private var job: Job? {
    controller.jobs.first { $0.id == jobID }
  }

  var body: some View {
    Group {
      if let job {
        content(for: job, info: JobInfo(job: job))
      } else {
        // The job was removed while its window was open. Saying so beats an
        // empty window, and beats closing itself out from under the user.
        ContentUnavailableView(
          "Download removed", systemImage: "tray",
          description: Text("This download is no longer in the queue."))
      }
    }
    .frame(minWidth: 420, minHeight: 360)
    .navigationTitle(job?.title ?? "Download")
    .task(id: JobInfo(job: job ?? emptyJob).sourceIdentifier) {
      await loadMetadata()
    }
  }

  private func content(for job: Job, info: JobInfo) -> some View {
    VStack(spacing: 0) {
      Form {
        Section {
          // Always drawn, never conditional: the fetch is a network round trip
          // and a card that appeared when it returned would jump the window by
          // its own height at an unpredictable moment.
          switch metadata {
          case .loading: VideoCard(.loading)
          case .loaded(let info): VideoCard(info: info)
          case .unavailable: VideoCard(.unavailable(title: job.title))
          }
          if let source = info.sourceURL {
            LabeledContent("Link") {
              // Selectable, because the reason to look at a link is usually to
              // take it somewhere else.
              Text(source.absoluteString)
                .textSelection(.enabled)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(source.absoluteString)
            }
          }
          LabeledContent("Status", value: JobPresentation.accessibilityStatus(of: job.status)
            .capitalized)
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
      footer(for: info)
    }
  }

  private func footer(for info: JobInfo) -> some View {
    HStack(spacing: 8) {
      Text("Saved to").foregroundStyle(.secondary)
      if let folder = info.destinationFolder {
        Image(nsImage: NSWorkspace.shared.icon(forFile: folder.path(percentEncoded: false)))
          .resizable()
          .frame(width: 16, height: 16)
        Text(folder.lastPathComponent)
          .lineLimit(1)
          .truncationMode(.middle)
          .help(folder.path(percentEncoded: false))
      } else {
        Text("Unknown").foregroundStyle(.secondary)
      }

      Spacer(minLength: 8)

      Button("Show in Finder") {
        NSWorkspace.shared.activateFileViewerSelecting(
          info.deliveredFiles.isEmpty
            ? [info.destinationFolder].compactMap { $0 }
            : info.deliveredFiles)
      }
      .disabled(info.destinationFolder == nil && info.deliveredFiles.isEmpty)
    }
    .padding(.horizontal, 20)
    .padding(.vertical, 14)
  }

  /// Re-fetches the video's metadata for the thumbnail and title.
  ///
  /// Not stored on the job: the queue keeps what a download *was told to do*,
  /// not what Twitch said about it, and adding a cached copy would be a second
  /// source of truth that goes stale. The fetch is the same one intake makes,
  /// and failing it costs only the thumbnail.
  private func loadMetadata() async {
    guard let job, let identifier = JobInfo(job: job).sourceIdentifier else {
      metadata = .unavailable
      return
    }
    if let info = try? await controller.fetchInfo(for: identifier) {
      metadata = .loaded(info)
    } else {
      // A private, deleted or expired VOD. The card falls back to the job's
      // own title, which was derived from that metadata when it still
      // resolved — so it is the best record of it that survives.
      metadata = .unavailable
    }
  }

  /// Stand-in so `.task(id:)` has something to key on when the job is gone.
  private var emptyJob: Job {
    Job(id: jobID, created: .now, title: "", steps: [])
  }
}

/// One step, as Get Info shows it: what it is, where it got to, and what the
/// helper said.
private struct StepInfoRow: View {
  let step: Step
  let log: (StepID) async -> String?

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack(spacing: QueueMetrics.iconSpacing) {
        let icon = JobPresentation.icon(for: step.status)
        Image(systemName: icon.name)
          .foregroundStyle(icon.tone.color)
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
        // The helper's own output, which the queue row no longer carries.
        // This is the window it was always really for.
        if showsLog {
          StepLogDisclosure(step: step, log: log, failure: failure)
        }
      }
      .padding(.leading, QueueMetrics.contentIndent)
    }
  }

  /// A finished step has no log to show: its workspace, log included, goes
  /// with it when the job succeeds. Offering an empty disclosure would be a
  /// control that can only ever say it has nothing.
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
      LabeledContent("Outputs", value: "Video, Chat (JSON), Rendered chat")
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

enum JobInfoPreviewData {
  static let rendered = Job(
    id: JobID(rawValue: UUID()), created: .now, title: "LeighXP - indie horror",
    steps: [
      Step(
        id: StepID(rawValue: UUID()),
        kind: .renderChat(RenderRequest(
          width: 420, height: 800, framerate: 60,
          destination: URL(filePath: "/tmp/r.mp4"))),
        status: .done),
    ])
}
