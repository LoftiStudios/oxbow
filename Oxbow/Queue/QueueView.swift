import AppKit
import SwiftUI
import OxbowKit

struct QueueView: View {
  let content: QueueContent
  let updates: UpdateModel

  /// Opens the intake window (`OxbowApp.intakeWindowID`). Intake is a window
  /// rather than a sheet on this one — see `IntakeWindow` for why — so the
  /// toolbar button hands off to the scene instead of presenting anything.
  @Environment(\.openWindow) private var openWindow

  /// Opening the release page is the update banner's whole action.
  @Environment(\.openURL) private var openURL

  @State private var selection: Set<JobID> = []

  /// A removal waiting on the user, and the dialog's own presentation flag.
  ///
  /// Two pieces of state rather than one optional driving a computed
  /// `Binding(get:set:)`: the binding form has to write `nil` back on dismiss,
  /// which means constructing a binding inside `body` that mutates the state
  /// `body` is reading. Separate flags keep the dismissal SwiftUI's business.
  @State private var isConfirmingRemoval = false
  @State private var jobsPendingRemoval: Set<JobID> = []

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
      // Below the warning, never above it. A missing helper means the app
      // cannot do its job at all, which outranks news about a version that
      // would have the same problem.
      if updates.state != .idle {
        UpdateBanner(
          state: updates.state,
          onOpen: { openURL($0) },
          onDismiss: { updates.dismiss() })
        Divider()
      }
      queue
    }
    .frame(minWidth: 480, minHeight: 320)
    .toolbar {
      ToolbarItem(placement: .primaryAction) {
        Button {
          openWindow(id: OxbowApp.intakeWindowID)
        } label: {
          Label("Add Download", systemImage: "plus")
        }
        // Kept alongside ⌘N deliberately: the shortcut is the fast path for
        // people who know it, and the button is how everyone else finds the
        // feature at all.
        .help("Add Download (⌘N)")
        .disabled(controller == nil)
      }
    }
  }

  /// The queue itself. With no controller there are no jobs, so this is the
  /// empty state with its action disabled — the banner above it says why.
  @ViewBuilder
  private var queue: some View {
    if let controller, !controller.jobs.isEmpty {
      List(selection: $selection) {
        ForEach(controller.jobs) { job in
          JobRow(
            job: job,
            onCancel: { Task { await controller.cancel(job: job.id) } },
            onRetryJob: { Task { await controller.retry(job: job.id) } },
            onRetryStep: { step in Task { await controller.retry(step: step) } },
            onRevealRetainedFiles: { id in Task { await controller.revealRetainedFiles(for: id) } },
            checkRevealTarget: { id in await controller.revealTarget(for: id) },
            retainedBytes: { id in await controller.retainedBytes(for: id) })
          .tag(job.id)
        }
      }
      // The system's own alternating row colours, not a colour of our own:
      // rows here vary wildly in height — a collapsed single-step job is one
      // line, an expanded composite is five — and banding is what lets the eye
      // tell where one job ends and the next begins. It costs nothing when
      // there is one job, since the first row is always the unshaded one.
      .alternatingRowBackgrounds()
      // Delete on the selection, which is what a Mac list does. Removal is the
      // thing this window had no way to do at all: every job ever enqueued
      // stayed on screen forever.
      .onDeleteCommand { requestRemoval(of: selection, from: controller) }
      // `forSelectionType:` rather than a per-row `.contextMenu`, so
      // right-clicking a row selects it first and a right-click on a
      // multi-row selection acts on all of it — both of which a per-row menu
      // gets wrong.
      .contextMenu(forSelectionType: JobID.self) { ids in
        QueueActionButtons(
          actions: actions(from: controller), ids: ids, presentation: .contextMenu)
      } primaryAction: { ids in
        // `primaryAction` is the double-click. Get Info, matching ⌘I — the
        // only gesture on a row that had no meaning, and the one Finder gives
        // to the same action.
        guard let id = ids.first, ids.count == 1 else { return }
        openWindow(id: OxbowApp.infoWindowID, value: id)
      }
      // Published for the menu bar. `focusedSceneValue` rather than
      // `focusedValue`: the Downloads menu has to work whenever this window is
      // frontmost, not only when the list itself holds keyboard focus.
      .focusedSceneValue(\.queueActions, actions(from: controller))
      .confirmationDialog(
        removalConfirmationTitle(for: jobsPendingRemoval, from: controller),
        isPresented: $isConfirmingRemoval)
      {
        Button("Remove", role: .destructive) {
          remove(jobsPendingRemoval, from: controller)
        }
        Button("Cancel", role: .cancel) { jobsPendingRemoval = [] }
      } message: {
        Text("The download will stop. Files already saved are not deleted.")
      }
    } else {
      ContentUnavailableView {
        Label("No downloads", systemImage: "tray")
      } description: {
        Text("Add a Twitch VOD to get started.")
      } actions: {
        Button("Add Download…") { openWindow(id: OxbowApp.intakeWindowID) }
          .disabled(controller == nil)
      }
      // Fills the space the `List` branch would, so the `VStack` above has a
      // child that expands. Without it the stack's children total less than
      // the window and get centred as a block — which left the update banner
      // floating in the middle of an empty window instead of sitting under
      // the toolbar. `ContentUnavailableView` still centres its own content
      // inside this, so the empty state looks unchanged.
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
  }

  // MARK: - Actions

  /// The queue's actions, bound to this controller.
  ///
  /// Removal goes back through `requestRemoval` rather than straight to the
  /// controller, so a Remove from the menu bar gets the same confirmation over
  /// a running download that the Delete key does.
  private func actions(from controller: QueueController) -> QueueActions {
    QueueActions(
      jobs: controller.jobs,
      selection: selection,
      remove: { requestRemoval(of: $0, from: controller) },
      retry: { job in Task { await controller.retry(job: job) } },
      cancel: { job in Task { await controller.cancel(job: job) } },
      showInfo: { openWindow(id: OxbowApp.infoWindowID, value: $0) })
  }

  // MARK: - Removal

  /// Removes immediately, or asks first when something is still running.
  ///
  /// The confirmation is not for the row — a row is cheap to lose — it is for
  /// the work. Removing a running job kills its helper, and a two-hour chat
  /// render deserves better than a mis-hit Delete key. Nothing settled asks.
  private func requestRemoval(of ids: Set<JobID>, from controller: QueueController) {
    guard !ids.isEmpty else { return }

    let running = controller.jobs.filter { ids.contains($0.id) && $0.status == .running }
    guard running.isEmpty else {
      jobsPendingRemoval = ids
      isConfirmingRemoval = true
      return
    }
    remove(ids, from: controller)
  }

  private func remove(_ ids: Set<JobID>, from controller: QueueController) {
    jobsPendingRemoval = []
    selection.subtract(ids)
    Task { await controller.remove(jobs: ids) }
  }

  /// Names what is about to be stopped, rather than asking abstractly. One
  /// running job is worth naming; several are worth counting.
  private func removalConfirmationTitle(
    for ids: Set<JobID>,
    from controller: QueueController)
    -> String
  {
    let running = controller.jobs.filter { ids.contains($0.id) && $0.status == .running }
    guard let only = running.first, running.count == 1 else {
      return "Remove \(running.count) downloads that are still running?"
    }
    return "Remove “\(only.title)” while it is still downloading?"
  }
}

#Preview("Helper missing") {
  QueueView(
    content: .unavailable("""
    The TwitchDownloaderCLI helper is not embedded in this build. Build it \
    with the dotnet publish command in docs/development.md, then build the \
    app again.
    """),
    updates: UpdateModel { .upToDate })
  .frame(width: 720, height: 420)
}

#Preview("Update available") {
  let updates = UpdateModel {
    .available(
      ReleaseVersion("0.3.0")!,
      URL(string: "https://github.com/LoftiStudios/oxbow/releases/tag/v0.3.0")!)
  }
  return QueueView(content: .unavailable("No helper in this build."), updates: updates)
    .frame(width: 720, height: 420)
    .task { await updates.checkAutomatically() }
}
