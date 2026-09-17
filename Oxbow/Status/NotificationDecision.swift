import Foundation
import OxbowKit

/// Pure snapshot diff identifying newly settled jobs.
nonisolated enum NotificationDecision {

  enum Outcome: Equatable {
    case finished
    case failed
  }

  struct Event: Equatable {
    let job: JobID
    let title: String
    let outcome: Outcome
    /// Carry reveal URLs into notification userInfo so response handling needs no current queue
    /// state.
    let files: [URL]
  }

  /// The baseline a later `events(from:to:)` diffs against.
  static func statuses(of jobs: [Job]) -> [JobID: JobStatus] {
    Dictionary(uniqueKeysWithValues: jobs.map { ($0.id, $0.status) })
  }

  /// Emit only transitions for jobs present in the previous snapshot. Startup, new jobs, and
  /// removal do not notify.
  static func events(from previous: [JobID: JobStatus], to snapshot: [Job]) -> [Event] {
    snapshot.compactMap { job in
      guard let was = previous[job.id], was != job.status else { return nil }

      let outcome: Outcome
      let files: [URL]
      switch job.status {
      case .done:
        outcome = .finished
        files = job.deliveredFiles
      case .failed:
        outcome = .failed
        // Failed jobs reveal no files, even if an earlier step delivered one.
        files = []
      // Cancellation is the user's own doing, and queued/running are not
      // terminal.
      case .cancelled, .queued, .running: return nil
      }

      return Event(
        job: job.id,
        title: job.title,
        outcome: outcome,
        files: files)
    }
  }
}
