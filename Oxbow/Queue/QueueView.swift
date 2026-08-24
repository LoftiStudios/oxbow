import SwiftUI
import OxbowKit

struct QueueView: View {
  let content: QueueContent

  @State private var isShowingIntake = false

  private var controller: QueueController? {
    if case .ready(let controller) = content { return controller }
    return nil
  }

  /// The window's one explanation slot, in precedence order.
  ///
  /// A missing payload outranks a queue file that failed to load: nothing can
  /// run at all, which is the more important thing to say, and the two cannot
  /// both be true anyway — without an engine there is no load to fail.
  private var banner: (title: String, message: String)? {
    switch content {
    case .unavailable(let message):
      return ("Downloads unavailable", message)
    case .ready(let controller):
      guard let failure = controller.startFailure else { return nil }
      return ("Saved queue not loaded", failure)
    }
  }

  var body: some View {
    VStack(spacing: 0) {
      if let banner {
        QueueBanner(title: banner.title, message: banner.message)
        Divider()
      }
      queue
    }
    .frame(minWidth: 480, minHeight: 320)
    .toolbar {
      ToolbarItem(placement: .primaryAction) {
        Button {
          isShowingIntake = true
        } label: {
          Label("Add Download", systemImage: "plus")
        }
        .disabled(controller == nil)
      }
    }
    .sheet(isPresented: $isShowingIntake) {
      // Unreachable without a controller — every control that sets this is
      // disabled in that case — but the sheet needs one, and there is no
      // honest thing to put here instead.
      if let controller {
        IntakeSheet(controller: controller)
      }
    }
  }

  /// The queue itself. With no controller there are no jobs, so this is the
  /// empty state with its action disabled — the banner above it says why.
  @ViewBuilder
  private var queue: some View {
    if let controller, !controller.jobs.isEmpty {
      List(controller.jobs) { job in
        JobRow(job: job) {
          Task { await controller.cancel(job: job.id) }
        } onRetry: { step in
          Task { await controller.retry(step: step) }
        }
      }
    } else {
      ContentUnavailableView {
        Label("No downloads", systemImage: "tray")
      } description: {
        Text("Add a Twitch VOD to get started.")
      } actions: {
        Button("Add Download…") { isShowingIntake = true }
          .disabled(controller == nil)
      }
    }
  }
}
