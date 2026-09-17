import SwiftUI
import OxbowKit

/// Reserve disclosure and status columns on every row so mixed single-step and multi-step jobs
/// align.
struct JobRow: View {
  let job: Job
  let onCancel: () -> Void
  /// Retry the whole job because cancellation settles every unfinished step; retrying only one
  /// would leave others cancelled.
  let onRetryJob: () -> Void
  /// Restarts one step, from the expanded step list.
  let onRetryStep: (StepID) -> Void
  /// Reveal job-scoped retained composite pieces from the step menu.
  let onRevealRetainedFiles: (JobID) -> Void
  /// Check the reveal target asynchronously on demand, outside the view body.
  let checkRevealTarget: (JobID) async -> RevealTarget?
  /// Read retained bytes from disk on demand; this is not persisted Job state.
  let retainedBytes: (JobID) async -> Int

  @Environment(\.colorScheme) private var colorScheme

  @State private var isExpanded = false
  @State private var bytesRetained: Int?

  private var isMultiStep: Bool { job.steps.count > 1 }

  /// Show representative-step details only when that step is not already expanded below. Header
  /// Retry remains job-scoped in either state.
  private var summarisesRepresentativeStep: Bool { !(isMultiStep && isExpanded) }

  /// Show retention for failed and cancelled jobs; cancellation does not delete retained
  /// pieces.
  private var isRetentionVisible: Bool {
    job.status == .failed || job.status == .cancelled
  }

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
            StepRow(
              step: step,
              jobStatus: job.status,
              onRetry: { onRetryStep(step.id) },
              onRevealRetainedFiles: { onRevealRetainedFiles(job.id) },
              checkRevealTarget: { await checkRevealTarget(job.id) })
              .padding(.leading, QueueMetrics.contentIndent)
          }
        }

        // Show retained bytes once per job, outside individual step details.
        if isRetentionVisible, let bytesRetained, bytesRetained > 0 {
          Text("\(ByteCountFormatter.string(fromByteCount: Int64(bytesRetained), countStyle: .file)) held — dismiss to reclaim")
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.leading, QueueMetrics.contentIndent)
        }
      }
    }
    .padding(.vertical, 4)
    // Clear the retained-byte count when retry moves the job out of a terminal state.
    .task(id: job.status) {
      guard isRetentionVisible else {
        bytesRetained = nil
        return
      }
      bytesRetained = await retainedBytes(job.id)
    }
    // Fixture-only expansion avoids embedding row coordinates in the screenshot harness.
    // Expansion is view state, not queue state.
    #if DEBUG
    .onAppear {
      if ScreenshotFixture.expandsJob(titled: job.title) { isExpanded = true }
    }
    #endif
  }

  /// Reserve the disclosure column even for single-step jobs.
  @ViewBuilder
  private var disclosure: some View {
    if isMultiStep {
      Button {
        isExpanded.toggle()
      } label: {
        Image(systemName: "chevron.right")
          .font(.caption)
          .foregroundStyle(.secondary)
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
        .foregroundStyle(icon.tone.color(for: colorScheme))
        .frame(width: QueueMetrics.icon, height: QueueMetrics.titleLine)
        .accessibilityHidden(true)

      Text(job.title)
        .lineLimit(1)
        // Preserve the suffix that distinguishes downloads of the same stream.
        .truncationMode(.middle)
        .help(job.title)

      Spacer(minLength: 8)

      // Queued work is cancellable too; the engine settles unadmitted steps.
      if job.status == .running || job.status == .queued {
        Button("Cancel", action: onCancel)
          .buttonStyle(.borderless)
          .controlSize(.small)
      }

      // Offer whole-job retry for both failure and cancellation.
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
        onRevealRetainedFiles: { _ in }, checkRevealTarget: { _ in nil },
        retainedBytes: { _ in 0 })
    }
  }
  .alternatingRowBackgrounds()
  .frame(width: 560, height: 320)
}

#Preview("Multi-step, expanded") {
  List {
    JobRow(
      job: JobRowPreviewData.multiStep,
      onCancel: {},
      onRetryJob: {},
      onRetryStep: { _ in },
      onRevealRetainedFiles: { _ in },
      checkRevealTarget: { _ in nil },
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
      onRevealRetainedFiles: { _ in },
      checkRevealTarget: { _ in nil },
      retainedBytes: { _ in 26_000_000_000 })
  }
  .frame(width: 560, height: 140)
}

/// Mixed-state fixtures expose row-alignment differences.
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
