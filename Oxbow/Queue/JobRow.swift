import SwiftUI
import OxbowKit

/// One job in the queue: its status, its title, whatever the representative
/// step is doing, and — for multi-step jobs — its steps underneath.
///
/// **Everything hangs off two reserved columns** (`QueueMetrics`): a gutter
/// that holds the disclosure control on rows that have one and stays empty on
/// rows that do not, and the status icon beside it. Rows used to lay
/// themselves out independently, so a row with a chevron pushed its icon right
/// of a row without one, and the failure message under a title started at the
/// row's own leading edge rather than under the title it explained. Reserving
/// the columns is what makes a list of mixed states line up.
struct JobRow: View {
  let job: Job
  let onCancel: () -> Void
  /// Restarts the whole job. Distinct from `onRetryStep` because cancelling
  /// settles *every* unfinished step, so a row-level Retry that only restarted
  /// the representative one would leave the rest cancelled forever
  /// (`Scheduler.retry(job:in:)`).
  let onRetryJob: () -> Void
  /// Restarts one step, from the expanded step list.
  let onRetryStep: (StepID) -> Void
  /// Bytes held in this job's retention area. An async closure rather than a
  /// plain value, matching `StepLogDisclosure.log` — it is a filesystem
  /// lookup the row makes on demand rather than state `Job` carries, so a row
  /// that is never failed never pays for it.
  let retainedBytes: (JobID) async -> Int

  @State private var isExpanded = false
  @State private var bytesRetained: Int?

  private var isMultiStep: Bool { job.steps.count > 1 }

  /// Whether the header stands in for the representative step.
  ///
  /// It does whenever the steps themselves are not on screen — which is
  /// every single-step job, since those get no disclosure control (design
  /// §4), and every collapsed multi-step one. What it governs now is only the
  /// *detail* — the progress line, the failure message, the log disclosure —
  /// so that a step's detail is drawn once and never twice. The row's own
  /// Retry is job-level and unconditional on this: it restarts the job
  /// whatever is expanded, and a step row's Retry restarts that one step.
  private var summarisesRepresentativeStep: Bool { !(isMultiStep && isExpanded) }

  var body: some View {
    let representative = JobPresentation.representativeStep(of: job)

    HStack(alignment: .top, spacing: QueueMetrics.gutterSpacing) {
      disclosure

      VStack(alignment: .leading, spacing: 4) {
        header()

        if summarisesRepresentativeStep, let representative {
          StepDetail(step: representative)
            .padding(.leading, QueueMetrics.contentIndent)
        }

        if isExpanded {
          ForEach(job.steps) { step in
            StepRow(step: step) { onRetryStep(step.id) }
              .padding(.leading, QueueMetrics.contentIndent)
          }
        }

        // Job-level, not step-level: the retention area belongs to the job as
        // a whole (it is what a resumed composite continues from), so this
        // sits under the header once regardless of which step is shown or
        // expanded — never duplicated per step.
        if job.status == .failed, let bytesRetained, bytesRetained > 0 {
          Text("\(ByteCountFormatter.string(fromByteCount: Int64(bytesRetained), countStyle: .file)) held — dismiss to reclaim")
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.leading, QueueMetrics.contentIndent)
        }
      }
    }
    .padding(.vertical, 4)
    // Keyed on status: a retry moves the job off `.failed` and the read is
    // no longer meaningful, so the stale byte count is dropped rather than
    // left showing on a row that is running again.
    .task(id: job.status) {
      guard job.status == .failed else {
        bytesRetained = nil
        return
      }
      bytesRetained = await retainedBytes(job.id)
    }
  }

  /// A disclosure control only where there is something to disclose — but the
  /// column it sits in is reserved either way.
  @ViewBuilder
  private var disclosure: some View {
    if isMultiStep {
      Button {
        isExpanded.toggle()
      } label: {
        Image(systemName: "chevron.right")
          .font(.caption)
          .foregroundStyle(.secondary)
          // Rotated rather than swapped for a second symbol, so the change
          // animates the way a real disclosure triangle does.
          .rotationEffect(.degrees(isExpanded ? 90 : 0))
          .frame(width: QueueMetrics.gutter, height: QueueMetrics.titleLine)
          .contentShape(.rect)
      }
      .buttonStyle(.plain)
      .animation(.snappy(duration: 0.15), value: isExpanded)
      .accessibilityLabel(isExpanded ? "Collapse steps" : "Expand steps")
    } else {
      Color.clear
        .frame(width: QueueMetrics.gutter, height: QueueMetrics.titleLine)
        .accessibilityHidden(true)
    }
  }

  private func header() -> some View {
    let icon = JobPresentation.icon(for: job.status)

    return HStack(spacing: QueueMetrics.iconSpacing) {
      Image(systemName: icon.name)
        .foregroundStyle(icon.tone.color)
        .frame(width: QueueMetrics.icon, height: QueueMetrics.titleLine)
        .accessibilityHidden(true)

      Text(job.title)
        .lineLimit(1)
        // Middle, not tail: these names end in a suffix that says what the
        // file is, and the end is often the only thing distinguishing two
        // downloads of the same stream.
        .truncationMode(.middle)
        .help(job.title)

      Spacer(minLength: 8)

      // Queued as well as running. A queued job has no process to kill,
      // but it does have steps the scheduler has not admitted yet, and
      // `QueueEngine.cancel(job:)` settles those correctly. The scheduler
      // admits one step per resource class, so the second of two VODs sits
      // queued for the whole of the first download — long enough that
      // leaving it with no control at all is the common case, not an edge
      // one.
      if job.status == .running || job.status == .queued {
        Button("Cancel", action: onCancel)
          .buttonStyle(.borderless)
          .controlSize(.small)
      }

      // Retry on the row is job-level and offered for cancelled as much as
      // failed: nothing here can resume, so Retry means one thing — run it
      // again from scratch — and that is as reasonable for something you
      // stopped as for something that broke.
      if job.status == .failed || job.status == .cancelled {
        Button("Retry", action: onRetryJob)
          .buttonStyle(.borderless)
          .controlSize(.small)
      }
    }
    .accessibilityElement(children: .contain)
    .accessibilityLabel(Text("\(job.title), \(JobPresentation.accessibilityStatus(of: job.status))"))
  }
}

#Preview("Mixed states") {
  List {
    ForEach(JobRowPreviewData.jobs) { job in
      JobRow(
        job: job, onCancel: {}, onRetryJob: {}, onRetryStep: { _ in },
        retainedBytes: { _ in 0 })
    }
  }
  .frame(width: 560, height: 320)
}

#Preview("Multi-step, expanded") {
  List {
    JobRow(
      job: JobRowPreviewData.multiStep,
      onCancel: {},
      onRetryJob: {},
      onRetryStep: { _ in },
      retainedBytes: { _ in 0 })
  }
  .frame(width: 560, height: 260)
}

#Preview("Failed, holding retained bytes") {
  List {
    JobRow(
      job: JobRowPreviewData.failedWithRetention,
      onCancel: {},
      onRetryJob: {},
      onRetryStep: { _ in },
      // A six-hour stream's worth of retained pieces — resume.md §8's own
      // example, so the row and the doc agree on what "non-trivial" means.
      retainedBytes: { _ in 26_000_000_000 })
  }
  .frame(width: 560, height: 140)
}

/// Fake jobs for the previews above. Every state the row can be in, in one
/// list, because the alignment problems this row was rewritten to fix only
/// show up when the states are mixed.
enum JobRowPreviewData {
  private static func step(
    _ status: StepStatus,
    kind: StepKind = .downloadVideo(VideoRequest(
      videoID: "1", quality: "", destination: URL(filePath: "/tmp/a.mp4"))))
    -> Step
  {
    Step(id: StepID(rawValue: UUID()), kind: kind, status: status)
  }

  private static func job(_ title: String, _ statuses: [StepStatus]) -> Job {
    Job(
      id: JobID(rawValue: UUID()), created: .now, title: title,
      steps: statuses.map { step($0) })
  }

  static let jobs: [Job] = [
    job("LeighXP - 2026-08-12 - indie horror + something else later??", [.running]),
    job("xQc - 2026-08-19 - Me on stream", [.done]),
    job("Video 2838257739", [.queued]),
    job(
      "Video 1754808548",
      [.failed(StepFailure(kind: .interrupted, summary: "Interrupted"))]),
    job("Video 2844548319", [.cancelled]),
  ]

  static let failedWithRetention = job(
    "LeighXP - 2026-08-19 - twelve-hour marathon",
    [.failed(StepFailure(
      kind: .exited(code: 1),
      summary: "The chat renderer exited with code 1."))])

  static let multiStep = Job(
    id: JobID(rawValue: UUID()), created: .now,
    title: "LeighXP - 2026-08-12 - indie horror + something else later??",
    steps: [
      step(.done, kind: .downloadChat(ChatRequest(videoID: "1", format: .json))),
      step(.running),
      step(.queued, kind: .renderChat(RenderRequest(destination: URL(filePath: "/tmp/r.mp4")))),
    ])
}
