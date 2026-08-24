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
        if case .failed = step.status {
          Button("Retry", action: onRetry)
            .buttonStyle(.link)
        }
      }

      if case .failed(let failure) = step.status {
        Text(failure.summary)
          .font(.caption)
          .foregroundStyle(.red)
          .textSelection(.enabled)
      } else if step.status == .running {
        ProgressLine(progress: step.progress)
      }
    }
    .padding(.vertical, 2)
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
