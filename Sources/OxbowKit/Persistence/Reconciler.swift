import Foundation

/// Reconciles loaded steps with usable artifacts on disk. Preserve completed downloads while
/// resetting missing intermediates needed by retryable jobs.
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

      // Completed jobs intentionally lost their intermediates during cleanup; do not reopen
      // them. Failed and cancelled jobs still need missing inputs requeued for retry.
      guard job.status != .done else { return job }

      for index in job.steps.indices {
        switch job.steps[index].status {
        case .running:
          // Mark the interrupted step failed; retry handles any resumable output.
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
