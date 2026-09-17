import AppKit
import SwiftUI
import OxbowKit

/// Align expanded steps with JobRow using the same QueueMetrics columns.
struct StepRow: View {
  let step: Step
  /// Job status triggers composite reveal checks when retention is removed after delivery.
  let jobStatus: JobStatus
  let onRetry: () -> Void
  /// Reveal retained composite pieces or the delivered file; JobRow binds the owning job.
  let onRevealRetainedFiles: () -> Void
  /// Read filesystem-backed reveal availability in a task, not the view body.
  let checkRevealTarget: () async -> RevealTarget?

  @Environment(\.colorScheme) private var colorScheme

  @State private var revealTarget: RevealTarget?

  var body: some View {
    // Attach the menu only to composites; an attached but empty context menu still produces a
    // visual artifact.
    if case .composite = step.kind {
      rowContent
        .contextMenu {
          // Keep Show in Finder visible but disabled until a target exists.
          Button {
            onRevealRetainedFiles()
          } label: {
            Label("Show in Finder", systemImage: "folder")
          }
          .disabled(revealTarget == nil)
        }
        // Check both statuses: composite startup creates retention while the job is already
        // running; whole-job completion removes it after the composite step is already done.
        .task(id: RevealCheckTrigger(step: step.status, job: jobStatus)) {
          revealTarget = await checkRevealTarget()
        }
    } else {
      rowContent
    }
  }

  private var rowContent: some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack(spacing: QueueMetrics.iconSpacing) {
        Image(systemName: icon.name)
          .foregroundStyle(icon.tone.color(for: colorScheme))
          .frame(width: QueueMetrics.icon, height: QueueMetrics.titleLine)
          .accessibilityHidden(true)

        Text(JobPresentation.label(for: step.kind))
          .font(.subheadline)

        Spacer(minLength: 8)

        RetryButton(step: step, action: onRetry)
      }

      StepDetail(step: step)
        .padding(.leading, QueueMetrics.contentIndent)
    }
    .padding(.vertical, 2)
  }

  private var icon: (name: String, tone: JobPresentation.Tone) {
    JobPresentation.icon(for: step.status)
  }
}

private struct RevealCheckTrigger: Equatable {
  var step: StepStatus
  var job: JobStatus
}

/// Shared Retry control for collapsed job rows and expanded steps.
struct RetryButton: View {
  let step: Step
  let action: () -> Void

  var body: some View {
    if isRetryable {
      Button("Retry", action: action)
        .buttonStyle(.borderless)
        .controlSize(.small)
    }
  }

  private var isRetryable: Bool {
    switch step.status {
    case .failed, .cancelled: true
    case .queued, .blocked, .running, .done: false
    }
  }
}

/// Shared failure or progress detail; full helper logs belong in Get Info.
struct StepDetail: View {
  let step: Step

  var body: some View {
    if case .failed(let failure) = step.status {
      Text(failure.summary)
        .font(.caption)
        .foregroundStyle(.red)
        .textSelection(.enabled)
        .fixedSize(horizontal: false, vertical: true)
    } else if step.status == .running {
      ProgressLine(progress: step.progress, phases: StepPhases.expected(for: step.kind))
    }
  }
}

/// Load logs on demand instead of adding large output strings to every persisted queue
/// snapshot.
struct StepLogDisclosure: View {
  let step: Step
  let log: (StepID) async -> String?
  let failure: StepFailure?

  @State private var isExpanded = false
  @State private var contents: String?

  private var text: String {
    // Show stderr before the log; CLI exceptions usually appear there.
    [failure?.detail, contents]
      .compactMap { $0 }
      .joined(separator: "\n")
  }

  var body: some View {
    // Keep the disclosure available even if reading reveals an empty log.
    DisclosureGroup(isExpanded: $isExpanded) {
      VStack(alignment: .leading, spacing: 4) {
        ScrollView {
          Text(text.isEmpty ? "No output was captured." : text)
            .font(.system(.caption, design: .monospaced))
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxHeight: 180)

        Button("Copy") {
          NSPasteboard.general.clearContents()
          NSPasteboard.general.setString(text, forType: .string)
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
        .disabled(text.isEmpty)
      }
    } label: {
      Text("Details").font(.caption).foregroundStyle(.secondary)
    }
    .task(id: isExpanded) {
      // Reload on expansion because running steps keep appending output.
      guard isExpanded else { return }
      contents = await log(step.id)
    }
  }
}

/// The progress bar plus its caption, shared by job and step rows.
struct ProgressLine: View {
  let progress: StepProgress
  /// Use segments for known phases; otherwise fall back to a single bar.
  var phases: StepPhases?

  @Environment(\.colorScheme) private var colorScheme

  var body: some View {
    let display = ProgressDisplay(progress: progress)
    let segmented = phases.flatMap { $0.index(matching: progress) != nil ? $0 : nil }

    VStack(alignment: .leading, spacing: 3) {
      if let segmented {
        PhaseProgressBar(phases: segmented, progress: progress)
      } else if display.isIndeterminate {
        ProgressView().progressViewStyle(.linear)
      } else {
        ProgressView(value: display.fraction ?? 0)
      }

      HStack(spacing: 6) {
        if let phase = display.phase { Text(phase) }
        // Segments already show the phase count.
        if segmented == nil, let counter = display.counter { Text(counter) }
        if let rate = display.rate { Text(rate) }
        if let remaining = display.remaining { Text(remaining) }
        if let size = display.projectedSize { Text(size) }
      }
      .font(.caption)
      .foregroundStyle(.secondary)
      .monospacedDigit()
    }
    // Match ProgressView tint to the custom segmented bar's Brand fill.
    .tint(Brand.progressFill(for: colorScheme))
  }
}

#Preview("Running") {
  List {
    StepRow(
      step: Step(
        id: StepID(rawValue: UUID()),
        kind: .downloadVideo(VideoRequest(
          videoID: "1", quality: "", destination: URL(filePath: "/tmp/a.mp4"))),
        status: .running,
        progress: StepProgress(phase: "Downloading", fraction: 0.42, index: 2, total: 5)),
      jobStatus: .running,
      onRetry: {},
      onRevealRetainedFiles: {},
      checkRevealTarget: { nil })
  }
  .frame(width: 520, height: 200)
}

#Preview("Failed") {
  List {
    StepRow(
      step: Step(
        id: StepID(rawValue: UUID()),
        kind: .renderChat(RenderRequest(destination: URL(filePath: "/tmp/r.mp4"))),
        status: .failed(StepFailure(
          kind: .exited(code: 1),
          summary: "The chat renderer exited with code 1.",
          detail: "Unrecognized option 'crf'."))),
      jobStatus: .failed,
      onRetry: {},
      onRevealRetainedFiles: {},
      checkRevealTarget: { nil })
  }
  .frame(width: 520, height: 200)
}

/// Right-click to verify Show in Finder is present but disabled before compositing.
#Preview("Composite, not started — Show in Finder disabled") {
  List {
    StepRow(
      step: Step(
        id: StepID(rawValue: UUID()),
        kind: .composite(CompositeRequest(
          framerate: 30, duration: .seconds(60),
          destination: URL(filePath: "/tmp/out.mp4"))),
        status: .queued),
      jobStatus: .running,
      onRetry: {},
      onRevealRetainedFiles: {},
      checkRevealTarget: { nil })
  }
  .frame(width: 520, height: 200)
}

/// Right-click to verify retained pieces remain revealable after failure or cancellation.
#Preview("Composite, retention on disk — Show in Finder enabled") {
  List {
    StepRow(
      step: Step(
        id: StepID(rawValue: UUID()),
        kind: .composite(CompositeRequest(
          framerate: 30, duration: .seconds(3600),
          destination: URL(filePath: "/tmp/out.mp4"))),
        status: .running,
        progress: StepProgress(phase: "Combining", fraction: 0.63)),
      jobStatus: .running,
      onRetry: {},
      onRevealRetainedFiles: {},
      checkRevealTarget: {
        .retained(directory: URL(filePath: "/tmp/resume/abc"), pieces: [
          URL(filePath: "/tmp/resume/abc/piece-0.mp4"),
        ])
      })
  }
  .frame(width: 520, height: 200)
}

/// After delivery removes retention, Show in Finder must reveal the delivered file.
#Preview("Composite, delivered — Show in Finder points at the real file") {
  List {
    StepRow(
      step: Step(
        id: StepID(rawValue: UUID()),
        kind: .composite(CompositeRequest(
          framerate: 30, duration: .seconds(3600),
          destination: URL(filePath: "/Users/someone/Downloads/out.mp4"))),
        status: .done),
      jobStatus: .done,
      onRetry: {},
      onRevealRetainedFiles: {},
      checkRevealTarget: {
        .delivered(URL(filePath: "/Users/someone/Downloads/out.mp4"))
      })
  }
  .frame(width: 520, height: 200)
}
