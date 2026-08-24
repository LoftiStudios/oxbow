import Foundation

/// Brings a loaded queue back in line with what is actually on disk.
///
/// Nothing resumes, but a naive "reset everything" would redo a completed 4 GB
/// video download because a later render failed. The artifact check is what
/// makes the distinction: a file moved to the user's folder survives, an
/// intermediate that only ever lived in the job workspace does not.
public enum Reconciler {

  /// - Parameter artifactExists: whether a recorded artifact is still usable —
  ///   present *and* non-empty, per the design spec §1.5. Injected so this
  ///   stays a pure function.
  public static func reconcile(
    _ jobs: [Job],
    artifactExists: (URL) -> Bool)
    -> [Job]
  {
    jobs.map { job in
      var job = job

      // A job that already reached `.done` is finished, and its intermediates
      // were deliberately deleted when it finished. Requeueing a step of one
      // would un-finish a job the user has already been shown as complete and
      // re-download something that is only going to be discarded again — see
      // the design spec, §5. Nothing here can make such a job progress, so
      // there is nothing to reconcile.
      //
      // Deliberately only `.done`, not every terminal status: a `.failed` or
      // `.cancelled` job can still be retried, and a retry must re-fetch an
      // intermediate that no longer exists rather than run against a path
      // pointing at nothing.
      guard job.status != .done else { return job }

      for index in job.steps.indices {
        switch job.steps[index].status {
        case .running:
          // The app died while this was running; there is no resume.
          job.steps[index].status = .failed(
            StepFailure(kind: .interrupted, summary: "Interrupted"))
          job.steps[index].artifact = nil

        case .done:
          guard let artifact = job.steps[index].artifact, artifactExists(artifact) else {
            job.steps[index].status = .queued
            job.steps[index].artifact = nil
            continue
          }

        case .queued, .blocked, .failed, .cancelled:
          continue
        }
      }
      return job
    }
  }
}
