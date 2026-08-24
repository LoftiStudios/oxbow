import SwiftUI
import OxbowKit

struct StepRow: View {
  let step: Step
  let onRetry: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack {
        Text(JobPresentation.label(for: step.kind))
          .font(.subheadline)
        Spacer()
        RetryButton(step: step, action: onRetry)
      }

      StepDetail(step: step)
    }
    .padding(.vertical, 2)
  }
}

/// Retry, for a failed step, and nothing at all otherwise.
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
    if case .failed = step.status {
      Button("Retry", action: action)
        .buttonStyle(.link)
    }
  }
}

/// A step's failure message or its progress line, whichever applies —
/// the same derivation wherever a step is drawn.
struct StepDetail: View {
  let step: Step

  var body: some View {
    if case .failed(let failure) = step.status {
      Text(failure.summary)
        .font(.caption)
        .foregroundStyle(.red)
        .textSelection(.enabled)
    } else if step.status == .running {
      ProgressLine(progress: step.progress)
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
    }
  }
}
