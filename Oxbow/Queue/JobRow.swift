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
  /// The tail of a step's captured helper output. A closure rather than the
  /// `QueueController` itself: it is the only thing these rows ever asked the
  /// controller for, and taking just that makes the row previewable and
  /// testable without an engine behind it.
  let log: (StepID) async -> String?
  let onCancel: () -> Void
  /// Restarts the whole job. Distinct from `onRetryStep` because cancelling
  /// settles *every* unfinished step, so a row-level Retry that only restarted
  /// the representative one would leave the rest cancelled forever
  /// (`Scheduler.retry(job:in:)`).
  let onRetryJob: () -> Void
  /// Restarts one step, from the expanded step list.
  let onRetryStep: (StepID) -> Void

  @State private var isExpanded = false

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
          StepDetail(step: representative, log: log)
            .padding(.leading, QueueMetrics.contentIndent)
        }

        if isExpanded {
          ForEach(job.steps) { step in
            StepRow(step: step, log: log) { onRetryStep(step.id) }
              .padding(.leading, QueueMetrics.contentIndent)
          }
        }
      }
    }
    .padding(.vertical, 4)
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
      JobRow(job: job, log: { _ in "…" }, onCancel: {}, onRetryJob: {}, onRetryStep: { _ in })
    }
  }
  .frame(width: 560, height: 320)
}

#Preview("Multi-step, expanded") {
  List {
    JobRow(
      job: JobRowPreviewData.multiStep,
      log: { _ in "[STATUS] - Rendering 42%" },
      onCancel: {},
      onRetryJob: {},
      onRetryStep: { _ in })
  }
  .frame(width: 560, height: 260)
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

  static let multiStep = Job(
    id: JobID(rawValue: UUID()), created: .now,
    title: "LeighXP - 2026-08-12 - indie horror + something else later??",
    steps: [
      step(.done, kind: .downloadChat(ChatRequest(videoID: "1", format: .json))),
      step(.running),
      step(.queued, kind: .renderChat(RenderRequest(destination: URL(filePath: "/tmp/r.mp4")))),
    ])
}
