import AppKit
import SwiftUI
import OxbowKit

/// Everything the Downloads menu and the queue's context menu can do, plus
/// enough of the queue's state to know when each of them applies.
///
/// **Published as a focused scene value, not read out of `QueueView`.** The
/// menu bar lives in `OxbowApp` and the selection lives in a view; a menu
/// command reaching into view state would have to be told which window it
/// meant. `focusedSceneValue` answers that for free — the queue publishes this
/// while its scene is active, so the whole menu greys out when the Add
/// Download window is frontmost, which is correct rather than incidental.
struct QueueActions {
  var jobs: [Job]
  var selection: Set<JobID>

  /// Routed back through `QueueView` rather than straight to the controller,
  /// so removal keeps going through the same confirmation the Delete key does.
  var remove: (Set<JobID>) -> Void
  /// Job-level, not step-level: cancelling settles every unfinished step, so
  /// retrying one of them would leave the rest cancelled. See
  /// `Scheduler.retry(job:in:)`.
  var retry: (JobID) -> Void
  var cancel: (JobID) -> Void
  /// Opens Get Info for one job.
  var showInfo: (JobID) -> Void

  func jobs(in ids: Set<JobID>) -> [Job] {
    jobs.filter { ids.contains($0.id) }
  }

  /// The files these jobs actually delivered.
  ///
  /// `Step.artifact` is the delivered path — `Reconciler` clears it for
  /// anything still sitting inside our own workspace — but a retained
  /// composite piece lives under `Workspace.resumeRoot`, deliberately
  /// *outside* the workspace (docs/design/resume.md §3), so `Reconciler`
  /// never reaches it, and retention only ever persists on a job that is
  /// *not* `.done` — exactly the case `Reconciler` short-circuits for. A
  /// failed or cancelled composite job can therefore still have its step
  /// pointing at `resume/<jobid>/piece-N.mp4` here. Pieces are never
  /// delivered — only `.assemble`'s output is (§7) — so the composite step's
  /// artifact is excluded outright rather than trusted to already be gone.
  func deliveredFiles(in ids: Set<JobID>) -> [URL] {
    jobs(in: ids).flatMap { job in
      job.steps.compactMap { step in
        if case .composite = step.kind { return nil }
        return step.artifact
      }
    }
  }

  /// Jobs there is anything to restart in.
  ///
  /// **Cancelled counts, not only failed.** There is no resume anywhere in
  /// this stack, so retry has exactly one meaning — run it again from scratch
  /// with the settings it already has — and that is as valid a thing to want
  /// for something you stopped as for something that broke. Steps that
  /// already succeeded are never re-run; `Scheduler.retry(job:in:)` leaves
  /// them alone.
  func retryableJobs(in ids: Set<JobID>) -> [JobID] {
    jobs(in: ids).filter { $0.status == .failed || $0.status == .cancelled }.map(\.id)
  }

  /// Queued counts as cancellable: the scheduler admits one step per resource
  /// class, so a second VOD sits queued for the whole of the first download,
  /// and `QueueEngine.cancel(job:)` settles unadmitted steps correctly.
  func cancellableJobs(in ids: Set<JobID>) -> [JobID] {
    jobs(in: ids).filter { $0.status == .running || $0.status == .queued }.map(\.id)
  }

  /// Downloads that succeeded, and only those. A cancelled row was a decision
  /// and a failed row still has something to say; neither is swept by a menu
  /// item whose name promises to clear the finished ones.
  var completedJobs: Set<JobID> {
    Set(jobs.filter { $0.status == .done }.map(\.id))
  }
}

// MARK: - Focused value plumbing

struct QueueActionsKey: FocusedValueKey {
  typealias Value = QueueActions
}

extension FocusedValues {
  var queueActions: QueueActions? {
    get { self[QueueActionsKey.self] }
    set { self[QueueActionsKey.self] = newValue }
  }
}

// MARK: - The items themselves

/// The queue's actions, rendered once and used in both menus.
///
/// The menu bar and the context menu want the same actions and disagree about
/// one thing: what to do with an action that does not apply. A menu-bar menu
/// **disables** it, because a menu you cannot see into is a menu nobody
/// discovers. A context menu **omits** it, because a right-click that produces
/// five greyed-out lines reads as a list of things that are broken. That is
/// the only difference, and it is what `presentation` selects.
struct QueueActionButtons: View {
  enum Presentation {
    /// Everything, always, disabled when it does not apply.
    case menuBar
    /// Only what applies, and no key equivalents — the menu bar owns those.
    case contextMenu
  }

  let actions: QueueActions
  /// What to act on. The menu bar passes the selection; the context menu
  /// passes what was right-clicked, which is not always the same set.
  let ids: Set<JobID>
  var presentation: Presentation = .menuBar

  private var isMenuBar: Bool { presentation == .menuBar }

  var body: some View {
    let files = actions.deliveredFiles(in: ids)
    let retryable = actions.retryableJobs(in: ids)
    let cancellable = actions.cancellableJobs(in: ids)
    let completed = actions.completedJobs
    // One at a time. Get Info opens a window per job, and ⌘I on eight selected
    // rows opening eight windows is a worse outcome than a disabled item.
    let single = ids.count == 1 ? ids.first : nil

    if isMenuBar || single != nil {
      Button {
        if let single { actions.showInfo(single) }
      } label: {
        Label("Get Info", systemImage: "info.circle")
      }
      .disabled(single == nil)
      .keyboardShortcut(isMenuBar ? KeyboardShortcut("i") : nil)
    }

    if isMenuBar || !files.isEmpty {
      Button {
        NSWorkspace.shared.activateFileViewerSelecting(files)
      } label: {
        Label("Show in Finder", systemImage: "folder")
      }
      .disabled(files.isEmpty)
      .keyboardShortcut(isMenuBar ? KeyboardShortcut("r") : nil)
    }

    if isMenuBar || !retryable.isEmpty {
      Button {
        for job in retryable { actions.retry(job) }
      } label: {
        Label("Retry", systemImage: "arrow.clockwise")
      }
      .disabled(retryable.isEmpty)
      .keyboardShortcut(isMenuBar ? KeyboardShortcut("r", modifiers: [.command, .shift]) : nil)
    }

    if isMenuBar || !cancellable.isEmpty {
      Button {
        for job in cancellable { actions.cancel(job) }
      } label: {
        Label("Cancel", systemImage: "stop.circle")
      }
      .disabled(cancellable.isEmpty)
      .keyboardShortcut(isMenuBar ? KeyboardShortcut(".") : nil)
    }

    Divider()

    // Not a trash icon, on either of these. Removing a row removes it from
    // the queue and deletes our own workspace; the file the download produced
    // stays exactly where the user asked for it. A trash can would promise
    // otherwise, which is the one thing this action must never imply.
    if isMenuBar || !ids.isEmpty {
      Button(role: .destructive) {
        actions.remove(ids)
      } label: {
        Label("Remove", systemImage: "minus.circle")
      }
      .disabled(ids.isEmpty)
      .keyboardShortcut(isMenuBar ? KeyboardShortcut(.delete) : nil)
    }

    if isMenuBar {
      Button(role: .destructive) {
        actions.remove(completed)
      } label: {
        Label("Remove Completed", systemImage: "eraser")
      }
      .disabled(completed.isEmpty)
      .keyboardShortcut(KeyboardShortcut(.delete, modifiers: [.command, .option]))
    }
  }
}

/// The `Downloads` menu in the menu bar.
///
/// Reads the queue's actions out of the focused scene, so it is live when the
/// queue window is frontmost and inert when the Add Download window is.
struct DownloadsCommands: Commands {
  @FocusedValue(\.queueActions) private var actions

  var body: some Commands {
    CommandMenu("Downloads") {
      if let actions {
        QueueActionButtons(actions: actions, ids: actions.selection)
      } else {
        // The queue scene is not frontmost. The menu still exists — a menu
        // that vanishes is worse than one that is greyed — it just has
        // nothing to act on.
        QueueActionButtons(actions: .empty, ids: [])
      }
    }
  }
}

extension QueueActions {
  /// Stand-in for "no queue is focused": every derivation comes back empty, so
  /// every item disables itself without any of them needing to know why.
  static let empty = QueueActions(
    jobs: [], selection: [], remove: { _ in }, retry: { _ in }, cancel: { _ in },
    showInfo: { _ in })
}

#Preview("Menu items") {
  let actions = QueueActions(
    jobs: JobRowPreviewData.jobs,
    selection: Set(JobRowPreviewData.jobs.map(\.id)),
    remove: { _ in },
    retry: { _ in },
    cancel: { _ in },
    showInfo: { _ in })

  return Menu("Downloads") {
    QueueActionButtons(actions: actions, ids: actions.selection)
  }
  .menuStyle(.borderlessButton)
  .padding()
  .frame(width: 240)
}
