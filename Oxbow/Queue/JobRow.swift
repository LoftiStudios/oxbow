import SwiftUI
import OxbowKit

struct JobRow: View {
  let job: Job
  let onCancel: () -> Void
  let onRetry: (StepID) -> Void

  @State private var isExpanded = false

  private var isMultiStep: Bool { job.steps.count > 1 }

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack(spacing: 8) {
        // A disclosure control only where there is something to disclose:
        // with one step the row already shows everything.
        if isMultiStep {
          Button {
            isExpanded.toggle()
          } label: {
            Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
          }
          .buttonStyle(.plain)
          .accessibilityLabel(isExpanded ? "Collapse steps" : "Expand steps")
        }

        let icon = JobPresentation.icon(for: job.status)
        Image(systemName: icon.name)
          .foregroundStyle(icon.isError ? .red : .secondary)

        Text(job.title)
        Spacer()

        if job.status == .running {
          Button("Cancel", action: onCancel).buttonStyle(.link)
        }
      }

      if let step = JobPresentation.representativeStep(of: job) {
        if case .failed(let failure) = step.status {
          Text(failure.summary)
            .font(.caption)
            .foregroundStyle(.red)
            .textSelection(.enabled)
        } else if step.status == .running {
          ProgressLine(progress: step.progress)
        }
      }

      if isExpanded {
        ForEach(job.steps) { step in
          StepRow(step: step) { onRetry(step.id) }
            .padding(.leading, 20)
        }
      }
    }
    .padding(.vertical, 4)
  }
}
