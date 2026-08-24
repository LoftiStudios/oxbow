import Foundation

/// Owns the on-disk scratch space for jobs.
///
/// Per job rather than per step, because chained steps hand artifacts to each
/// other and an intermediate must outlive the step that produced it.
///
/// We own this rather than letting the CLI manage its own cache because the
/// CLI's cleanup sits in a `finally` block that never runs when we kill it.
public struct Workspace: Sendable {
  public let root: URL

  public init(root: URL) {
    self.root = root
  }

  public func jobDirectory(_ job: JobID) -> URL {
    root.appending(path: "jobs/\(job.rawValue.uuidString)")
  }

  /// Passed to the CLI as `--temp-path`.
  public func stepDirectory(job: JobID, step: StepID) -> URL {
    jobDirectory(job).appending(path: "step-\(step.rawValue.uuidString)")
  }

  /// Intermediates handed between steps.
  public func artifactsDirectory(_ job: JobID) -> URL {
    jobDirectory(job).appending(path: "artifacts")
  }

  @discardableResult
  public func prepareStep(job: JobID, step: StepID) throws -> URL {
    let directory = stepDirectory(job: job, step: step)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
  }

  @discardableResult
  public func prepareArtifacts(job: JobID) throws -> URL {
    let directory = artifactsDirectory(job)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
  }

  /// Correct however the process died — graceful exit, cancellation, or crash.
  public func removeStep(job: JobID, step: StepID) {
    try? FileManager.default.removeItem(at: stepDirectory(job: job, step: step))
  }

  public func removeJob(_ job: JobID) {
    try? FileManager.default.removeItem(at: jobDirectory(job))
  }

  /// Launch sweep. Nothing here can ever be reused, so there is no case to
  /// reason about and no way for a power loss to leak tens of gigabytes.
  public func removeAll() {
    try? FileManager.default.removeItem(at: root)
  }
}
