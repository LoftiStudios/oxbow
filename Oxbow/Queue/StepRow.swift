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
  /// Only consulted for the composite row's reveal check below, so a step
  /// that is not `.composite` never reads it — but it comes from `JobRow`
  /// unconditionally, the same way `onRevealRetainedFiles` does, since a
  /// step row cannot tell in advance which kind it is being built for.
  let jobStatus: JobStatus
  let onRetry: () -> Void
  /// Reveals the composite step's retained pieces — or, once those are gone
  /// because the job delivered, the delivered file itself. Job-scoped by the
  /// time it reaches this view — `JobRow` already closes over the job's
  /// `JobID`, since both live at the job level, not the step
  /// (`QueueEngine.revealTarget(forJob:)`) — so this row only has to decide
  /// whether to offer the item at all, never which job it is for.
  let onRevealRetainedFiles: () -> Void
  /// Whether there is currently anything for the item above to reveal.
  /// Filesystem-backed (`QueueEngine.revealTarget(forJob:)` checks whether
  /// the retention directory still exists), so it is read on a `.task`
  /// rather than computed inline in the body — see `revealTarget` below.
  let checkRevealTarget: () async -> RevealTarget?

  @State private var revealTarget: RevealTarget?

  var body: some View {
    // The context menu is attached only for `.composite` — not attached-but-
    // empty for everything else. `.contextMenu { if case .composite … }`
    // would leave every other row's closure evaluating to nothing, and an
    // attached-but-empty context menu is its own (SwiftUI-known) visual
    // artifact on right-click. Branching on whether to attach it at all
    // keeps every non-composite row exactly as it was before this item
    // existed.
    if case .composite = step.kind {
      rowContent
        .contextMenu {
          // Same wording and icon as `QueueActionButtons`' "Show in Finder" —
          // this reads as the same action, just scoped to the retention area
          // (or, once that is gone, the delivered file) instead of a job's
          // full set of delivered files. Deliberately just this one item
          // (docs/design/fragmented-output.md §6): present but disabled
          // when there is genuinely nothing to reveal yet, so the affordance
          // is discoverable ahead of being usable.
          Button {
            onRevealRetainedFiles()
          } label: {
            Label("Show in Finder", systemImage: "folder")
          }
          .disabled(revealTarget == nil)
        }
        // Keyed on both the step's own status and the job's. The step's,
        // because the retention directory first appears the moment the
        // composite step starts, and `Job.status` alone would never catch
        // that — it is already `.running` from an earlier step. The job's,
        // because the retention directory is *removed* only once the whole
        // job reaches `.done` (`QueueEngine.removeJobWorkspace`) — by which
        // point the composite step's own status stopped changing, settled at
        // `.done` since before the assemble step even started. Either alone
        // misses one of the two moments the filesystem actually changes.
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
          .foregroundStyle(icon.tone.color)
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

/// `.task(id:)`'s key for re-checking the composite row's reveal target —
/// see the doc comment on that call for why it needs both statuses rather
/// than either alone.
private struct RevealCheckTrigger: Equatable {
  var step: StepStatus
  var job: JobStatus
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
///
/// **No log disclosure here.** It used to carry one, from before Get Info
/// existed and the helper's output had nowhere else to live. A queue row's job
/// is status at a glance, and the one-line summary below a failed step is that;
/// the full output is depth, and depth belongs in the window built for it. The
/// disclosure had also stopped responding once the list became selectable,
/// which is a good reason to stop rather than to start fighting the row's
/// selection gesture for the click.
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
  /// The phases this step walks through, when we know them. A segmented bar
  /// needs them; without them this falls back to the single bar, which is
  /// still right for a step whose phases we cannot name.
  var phases: StepPhases?

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
        // Redundant once the segments are on screen: they already say which
        // of how many, and say it in the phase's own name.
        if segmented == nil, let counter = display.counter { Text(counter) }
        // Only FFmpeg's own steps (the composite) ever have this — it is
        // what tells "genuinely slow" apart from "looks stalled" without
        // opening the log.
        if let rate = display.rate { Text(rate) }
        if let remaining = display.remaining { Text(remaining) }
        if let size = display.projectedSize { Text(size) }
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

/// The composite step's own "Show in Finder" item — the one row that carries
/// it at all — before the combine has started. Right-click to see the item
/// present but disabled, per docs/design/fragmented-output.md §6.
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

/// The same row once the combine has started — the retention directory
/// exists on disk, so `revealTarget` comes back `.retained` and the item
/// enables. `.done`, `.failed`, and `.cancelled` all reach the same enabled
/// state, since retention persists until the whole job is either delivered
/// or removed. Right-click to see it enabled.
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

/// The job in question fully delivered: `removeJobWorkspace` already deleted
/// the retention area (docs/design/resume.md §8), so there is nothing left
/// on disk to point at — but the job did produce a file, and that is what
/// this item reveals instead of going dead. This is Fix 2's whole reason for
/// existing: before it, this state left the item enabled with nothing behind
/// it. Right-click to see it enabled, pointing at the delivered file.
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
