import Foundation
import OxbowKit

/// Which jobs have just reached a terminal state, by diffing two snapshots.
///
/// `nonisolated` for the same reason as `QueueStatus`: pure, no UI
/// dependency, called synchronously from `OxbowTests`.
nonisolated enum NotificationDecision {

  enum Outcome: Equatable {
    case finished
    case failed
  }

  struct Event: Equatable {
    let job: JobID
    let title: String
    let outcome: Outcome
    /// What "Show in Finder" reveals. Carried in the event — and from there
    /// into the notification's `userInfo` — rather than looked up when the
    /// user clicks, so the action needs no access to queue state that may
    /// have moved on by then.
    let files: [URL]
  }

  /// The baseline a later `events(from:to:)` diffs against.
  static func statuses(of jobs: [Job]) -> [JobID: JobStatus] {
    Dictionary(uniqueKeysWithValues: jobs.map { ($0.id, $0.status) })
  }

  /// Jobs that have just settled.
  ///
  /// **A job absent from `previous` never fires.** That single rule delivers
  /// three behaviours at once: the first snapshot after launch seeds silently
  /// (spec §7.1), a newly enqueued job is not an event, and a removed job is
  /// not an event either. There is deliberately no separate "have we seeded
  /// yet" flag — a flag is a second thing that can be wrong.
  static func events(from previous: [JobID: JobStatus], to snapshot: [Job]) -> [Event] {
    snapshot.compactMap { job in
      guard let was = previous[job.id], was != job.status else { return nil }

      let outcome: Outcome
      switch job.status {
      case .done: outcome = .finished
      case .failed: outcome = .failed
      // Cancellation is the user's own doing, and queued/running are not
      // terminal.
      case .cancelled, .queued, .running: return nil
      }

      return Event(
        job: job.id,
        title: job.title,
        outcome: outcome,
        files: job.deliveredFiles)
    }
  }
}
