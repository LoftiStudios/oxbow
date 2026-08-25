import AppKit
import SwiftUI
import OxbowKit

/// One step of an expanded multi-step job.
///
/// Laid out on the same two columns as `JobRow` (`QueueMetrics`): a reserved
/// gutter where the job row's disclosure control sits, then the status icon,
/// then the name. That is what makes an expanded job's steps line up with the
/// job above them instead of starting at their own arbitrary indent.
struct StepRow: View {
  let step: Step
  let log: (StepID) async -> String?
  let onRetry: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack(spacing: QueueMetrics.iconSpacing) {
        Image(systemName: icon.name)
          .foregroundStyle(icon.tone.color)
          .frame(width: QueueMetrics.icon, height: QueueMetrics.titleLine)
          .accessibilityHidden(true)

        Text(JobPresentation.label(for: step.kind))
          .font(.subheadline)

        Spacer(minLength: 8)

        RetryButton(step: step, action: onRetry)
      }

      StepDetail(step: step, log: log)
        .padding(.leading, QueueMetrics.contentIndent)
    }
    .padding(.vertical, 2)
  }

  private var icon: (name: String, tone: JobPresentation.Tone) {
    JobPresentation.icon(for: step.status)
  }
}

/// Retry, for a step that did not finish, and nothing at all otherwise.
///
/// One definition, shared by the collapsed job row and the expanded step row.
/// Retry has to be reachable from the job row — a `.video` template expands
/// to exactly one step, and single-step jobs get no disclosure control
/// (design §4), so a step row is somewhere the user can never get to for the
/// only job kind this slice can create. Two hand-written buttons could
/// disagree about when a step is retryable; one type cannot.
struct RetryButton: View {
  let step: Step
  let action: () -> Void

  var body: some View {
    // Cancelled as well as failed. `Scheduler.retry(_:in:)` has always
    // accepted both; only the UI insisted a step had to have broken before it
    // could be run again.
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

/// A step's failure message or its progress line, whichever applies —
/// the same derivation wherever a step is drawn.
struct StepDetail: View {
  let step: Step
  let log: (StepID) async -> String?

  var body: some View {
    if case .failed(let failure) = step.status {
      Text(failure.summary)
        .font(.caption)
        .foregroundStyle(.red)
        .textSelection(.enabled)
        .fixedSize(horizontal: false, vertical: true)
      StepLogDisclosure(step: step, log: log, failure: failure)
    } else if step.status == .running {
      ProgressLine(progress: step.progress)
      // Offered while running too, not only on failure: a helper that has
      // finished its work and hung still reads as `.running`, and its last
      // few log lines are the only thing that says so.
      StepLogDisclosure(step: step, log: log, failure: nil)
    }
  }
}

/// What the helper actually said, behind a disclosure.
///
/// Loaded on demand rather than held in `Step`: the log is a file that can run
/// to hundreds of kilobytes, and every `Job` is re-encoded into the queue file
/// on a debounce during a download.
struct StepLogDisclosure: View {
  let step: Step
  let log: (StepID) async -> String?
  let failure: StepFailure?

  @State private var isExpanded = false
  @State private var contents: String?

  private var text: String {
    // stderr first: when a step failed, the CLI's exception usually lands
    // there while the narrative of what it was doing sits in the log.
    [failure?.detail, contents]
      .compactMap { $0 }
      .joined(separator: "\n")
  }

  var body: some View {
    // Always offered, never conditionally hidden: whether there is anything
    // to show is only knowable after reading the log, and a control that
    // disappears the moment you use it is worse than one that admits it has
    // nothing.
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
      // Re-read on each expand rather than once: a running step is still
      // writing, so a cached copy would show a stale tail.
      guard isExpanded else { return }
      contents = await log(step.id)
    }
  }
}

/// The progress bar plus its caption, shared by job and step rows.
struct ProgressLine: View {
  let progress: StepProgress

  var body: some View {
    let display = ProgressDisplay(progress: progress)
    VStack(alignment: .leading, spacing: 2) {
      if display.isIndeterminate {
        ProgressView().progressViewStyle(.linear)
      } else {
        ProgressView(value: display.fraction ?? 0)
      }

      HStack(spacing: 6) {
        if let phase = display.phase { Text(phase) }
        if let counter = display.counter { Text(counter) }
        if let remaining = display.remaining { Text(remaining) }
      }
      .font(.caption)
      .foregroundStyle(.secondary)
      .monospacedDigit()
    }
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
      log: { _ in "[STATUS] - Downloading 42% [2/5]" },
      onRetry: {})
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
      log: { _ in "" },
      onRetry: {})
  }
  .frame(width: 520, height: 200)
}
