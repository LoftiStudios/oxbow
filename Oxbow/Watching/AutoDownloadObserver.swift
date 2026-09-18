import Foundation
import OxbowKit

/// Return failed downloads to the inbox without retrying or deleting their jobs/retention.
/// Applies to manual and automatic submissions; cancellation alone does not re-offer an
/// archive.
@MainActor
final class AutoDownloadObserver {
  private let store: WatchStore

  /// Track transitions to failure, including failures in the first reconciled snapshot. Before
  /// unmarking, exclude media with a queued, running, or done sibling so an old failed job
  /// cannot undo a later retry after relaunch. Cancelled siblings do not count as recovery.
  private var baseline: [JobID: JobStatus] = [:]

  init(store: WatchStore) {
    self.store = store
  }

  /// Consume the shared QueueController snapshot subscription.
  func apply(_ jobs: [Job]) {
    let newlyFailed = jobs.compactMap { job -> String? in
      // Treat first-seen failures as transitions so startup reconciliation can return them to
      // the inbox.
      let was = baseline[job.id] ?? .queued
      guard was != job.status, job.status == .failed else { return nil }
      return job.mediaIdentifier
    }
    baseline = NotificationDecision.statuses(of: jobs)

    guard !newlyFailed.isEmpty else { return }
    let answered = mediaIdentifiersAlreadyAnswered(in: jobs)
    let toForget = newlyFailed.filter { !answered.contains($0) }
    guard !toForget.isEmpty else { return }
    forget(toForget)
  }

  /// Media with done, queued, or running jobs has already answered a failure; exclude it from
  /// unmarking. Failed and cancelled siblings do not qualify.
  private func mediaIdentifiersAlreadyAnswered(in jobs: [Job]) -> Set<String> {
    Set(jobs.compactMap { job -> String? in
      switch job.status {
      case .done, .queued, .running: return job.mediaIdentifier
      case .failed, .cancelled: return nil
      }
    })
  }

  /// Reload immediately before updating seen state, without suspension; refuse unreadable
  /// stores. Save is best effort and baseline already advanced, so a failed write is not
  /// retried on the next snapshot.
  private func forget(_ mediaIdentifiers: [String]) {
    guard let current = try? store.load() else { return }
    try? store.save(current.map { $0.forgetting(mediaIdentifiers) })
  }
}
