import Foundation

/// Brings a loaded queue back in line with what is actually on disk.
///
/// Nothing resumes, but a naive "reset everything" would redo a completed 4 GB
/// video download because a later render failed. The artifact check is what
/// makes the distinction: a file moved to the user's folder survives, an
/// intermediate that only ever lived in the job workspace does not.
public enum Reconciler {

  public static func reconcile(
    _ jobs: [Job],
    artifactExists: (URL) -> Bool)
    -> [Job]
  {
    jobs.map { job in
      var job = job
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
