import AppKit
import SwiftUI
import OxbowKit

/// Queue actions and selection state shared with menus through focusedSceneValue. Commands
/// disable when the queue scene is not focused.
struct QueueActions {
  var jobs: [Job]
  var selection: Set<JobID>

  /// Route removal through QueueView's confirmation, matching the Delete key.
  var remove: (Set<JobID>) -> Void
  /// Retry all unfinished steps; cancellation settles more than just the representative step.
  var retry: (JobID) -> Void
  var cancel: (JobID) -> Void
  /// Open the same video-keyed Get Info window as Watching, with JobID fallback for jobs
  /// without video identity.
  var showInfo: (InfoTarget) -> Void

  /// How to address one job's Get Info window: by its video when it has one,
  /// by the job itself when it does not.
  func infoTarget(for id: JobID) -> InfoTarget {
    guard let job = jobs.first(where: { $0.id == id }),
          let media = job.mediaIdentifier
    else { return .job(id) }
    return .video(media)
  }

  func jobs(in ids: Set<JobID>) -> [Job] {
    jobs.filter { ids.contains($0.id) }
  }

  /// Use Job.deliveredFiles to exclude intermediate artifacts, including successful steps that
  /// never deliver.
  func deliveredFiles(in ids: Set<JobID>) -> [URL] {
    jobs(in: ids).flatMap(\.deliveredFiles)
  }

  /// Retry failed or cancelled jobs while preserving successful steps; see
  /// Scheduler.retry(job:in:).
  func retryableJobs(in ids: Set<JobID>) -> [JobID] {
    jobs(in: ids).filter { $0.status == .failed || $0.status == .cancelled }.map(\.id)
  }

  /// Queued jobs can be cancelled before the scheduler admits their steps.
  func cancellableJobs(in ids: Set<JobID>) -> [JobID] {
    jobs(in: ids).filter { $0.status == .running || $0.status == .queued }.map(\.id)
  }

  /// Clear only successful jobs, preserving failed and cancelled rows.
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

/// Shared actions: disable inapplicable menu-bar items, omit them from context menus.
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
    // Get Info operates on one selected job at a time.
    let single = ids.count == 1 ? ids.first : nil

    if isMenuBar || single != nil {
      Button {
        if let single { actions.showInfo(actions.infoTarget(for: single)) }
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

    // Avoid a trash icon: removing queue entries preserves delivered files.
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
        Label("Remove Completed", systemImage: "text.badge.minus")
      }
      .disabled(completed.isEmpty)
      .keyboardShortcut(KeyboardShortcut(.delete, modifiers: [.command, .option]))
    }
  }
}

/// Downloads menu reads actions from the focused queue scene.
struct DownloadsCommands: Commands {
  @FocusedValue(\.queueActions) private var actions

  var body: some Commands {
    CommandMenu("Downloads") {
      if let actions {
        QueueActionButtons(actions: actions, ids: actions.selection)
      } else {
        QueueActionButtons(actions: .empty, ids: [])
      }
    }
  }
}

extension QueueActions {
  /// Empty actions keep the menu visible but disabled without a focused queue.
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
