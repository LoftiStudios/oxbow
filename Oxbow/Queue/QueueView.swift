import SwiftUI
import OxbowKit

struct QueueView: View {
  let controller: QueueController
  /// Non-nil when a payload is missing; the queue cannot run.
  let unavailable: String?

  @State private var isShowingIntake = false

  var body: some View {
    Group {
      if let unavailable {
        ContentUnavailableView {
          Label("Downloads unavailable", systemImage: "exclamationmark.triangle")
        } description: {
          Text(unavailable)
        }
      } else if controller.jobs.isEmpty {
        ContentUnavailableView {
          Label("No downloads", systemImage: "tray")
        } description: {
          Text("Add a Twitch VOD to get started.")
        } actions: {
          Button("Add Download…") { isShowingIntake = true }
        }
      } else {
        List(controller.jobs) { job in
          JobRow(job: job) {
            Task { await controller.cancel(job: job.id) }
          } onRetry: { step in
            Task { await controller.retry(step: step) }
          }
        }
      }
    }
    .frame(minWidth: 480, minHeight: 320)
    .toolbar {
      ToolbarItem(placement: .primaryAction) {
        Button {
          isShowingIntake = true
        } label: {
          Label("Add Download", systemImage: "plus")
        }
        .disabled(unavailable != nil)
      }
    }
    .sheet(isPresented: $isShowingIntake) {
      IntakeSheet(controller: controller)
    }
  }
}
