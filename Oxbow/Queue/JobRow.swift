import SwiftUI
import OxbowKit

struct JobRow: View {
  let job: Job
  let onCancel: () -> Void
  let onRetry: (StepID) -> Void

  @State private var isExpanded = false

  private var isMultiStep: Bool { job.steps.count > 1 }

  /// Whether the header stands in for the representative step.
  ///
  /// It does whenever the steps themselves are not on screen — which is
  /// every single-step job, since those get no disclosure control (design
  /// §4), and every collapsed multi-step one. The expansion carries actions,
  /// not just detail, so a row that summarises a step has to offer that
  /// step's actions too: a `.video` template expands to exactly one step, so
  /// without this Retry is unreachable for every job this slice can create.
  /// Exactly one row offers a given step's actions at a time, so the header
  /// and a step row can never present two competing controls for it.
  private var summarisesRepresentativeStep: Bool { !(isMultiStep && isExpanded) }

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      let representative = JobPresentation.representativeStep(of: job)

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

        // Queued as well as running. A queued job has no process to kill,
        // but it does have steps the scheduler has not admitted yet, and
        // `QueueEngine.cancel(job:)` settles those correctly. The scheduler
        // admits one step per resource class, so the second of two VODs sits
        // queued for the whole of the first download — long enough that
        // leaving it with no control at all is the common case, not an edge
        // one.
        if job.status == .running || job.status == .queued {
          Button("Cancel", action: onCancel)
            .buttonStyle(.link)
        }

        if summarisesRepresentativeStep, let representative {
          RetryButton(step: representative) { onRetry(representative.id) }
        }
      }

      if summarisesRepresentativeStep, let representative {
        StepDetail(step: representative)
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
