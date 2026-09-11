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
  let target: InfoTarget
  let controller: QueueController

  /// Where an expired video's metadata comes from once Twitch has stopped
  /// answering for it. Optional for the same reason `imageStore` is on the
  /// watching surfaces: `OxbowApp` builds it only once a support directory
  /// resolves, and never under `xcodebuild test`.
  let record: VideoRecordStore?

  /// Where the metadata fetch has got to.
  ///
  /// `VideoInfoLoad`, shared with `InspectorPane` — see that type. The states
  /// and the order they are attempted in are unchanged by the extraction;
  /// they simply live somewhere both surfaces can reach.
  @State private var metadata: VideoInfoLoad = .loading

  /// The download this window can talk about, when the queue still holds one.
  ///
  /// **Nil is an ordinary state now, not an error.** Keyed by video, this
  /// window is asked about archives nobody has downloaded and about downloads
  /// whose jobs have been cleared away; in both cases there is still a video
  /// to describe. Only the job-keyed case treats a missing job as something
  /// gone wrong, because there the job *was* the subject.
  ///
  /// One media id can name several jobs — a retry after a delete leaves the
  /// old one behind — so this picks the one a person is actually waiting on,
  /// in the same order `ArchiveRowState` reads them: still running, then
  /// finished, then whatever is left.
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
        // A video with no download behind it — a watched archive nobody has
        // fetched, or one whose job has been cleared out of the queue. There
        // is still a video to describe, which is the whole reason this window
        // stopped being keyed by the job.
        videoOnlyContent
      } else {
        // The job was removed while its window was open. Saying so beats an
        // empty window, and beats closing itself out from under the user.
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

  /// Everything this window can say about a video nothing has downloaded.
  ///
  /// Deliberately the same card, in the same place, as the job case above —
  /// a video should not look like a different kind of thing depending on
  /// whether a download happened to exist for it. What is missing is only the
  /// sections that describe a download, because there is no download.
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

  /// Re-fetches the video's metadata for the thumbnail and title.
  ///
  /// Not stored on the job: the queue keeps what a download *was told to do*,
  /// not what Twitch said about it, and adding a cached copy would be a second
  /// source of truth that goes stale. The fetch is the same one intake makes,
  /// and failing it costs only the thumbnail.
  private func loadMetadata() async {
    metadata = await VideoInfoLoad.resolve(
      identifier: videoIdentifier, controller: controller, record: record)
  }

}

/// The job's status, drawn the way the queue draws it: the same symbol and
/// the same tone, not a second vocabulary for the same five states. A window
/// opened from a row should agree with the row it was opened from — at a
/// glance, before the word is read.
///
/// The word stays. The icon is the glanceable half and the word is the exact
/// one, and this row is the only place in the app that has room for both.
/// It is also what keeps the row legible to VoiceOver, which is why the image
/// is hidden from it here for the same reason it is in `JobRow`.
/// **Internal, not private: `InspectorPane` renders the same row.** The two
/// surfaces must not develop separate vocabularies for the same five states —
/// a status that reads "Done" in one place and "Finished" in another is the
/// drift this whole design keeps refusing.
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

/// Every status the row can show, in one place: the five colours and glyphs
/// are the whole point of the row, and each is otherwise reachable only by
/// getting a real download into that state.
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
  /// A composite job: a render step feeding a composite, the only shape
  /// `renderSettings` now has anything to say about (see `JobInfo.swift`).
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
