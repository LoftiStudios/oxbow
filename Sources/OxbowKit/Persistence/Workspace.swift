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

  /// The only subtree of `root` this type creates. Scoped deliberately: `root`
  /// is the app's whole cache directory, and the launch sweep must not take
  /// anything else in it with it.
  public var jobsRoot: URL {
    root.appending(path: "jobs")
  }

  public func jobDirectory(_ job: JobID) -> URL {
    jobsRoot.appending(path: job.rawValue.uuidString)
  }

  /// Passed to the CLI as `--temp-path`.
  public func stepDirectory(job: JobID, step: StepID) -> URL {
    jobDirectory(job).appending(path: "step-\(step.rawValue.uuidString)")
  }

  /// Intermediates handed between steps.
  public func artifactsDirectory(_ job: JobID) -> URL {
    jobDirectory(job).appending(path: "artifacts")
  }

  /// Where a step's captured helper output lives.
  ///
  /// Under the job, not the step: `removeStep` deletes a step's directory the
  /// moment it ends, which is exactly when someone wants to read why it
  /// failed. Logs outlive their step for the same reason artifacts do.
  public func logFile(job: JobID, step: StepID) -> URL {
    jobDirectory(job).appending(path: "logs").appending(path: "\(step.rawValue).log")
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

  /// True when `url` names a file inside this job's workspace — i.e. an
  /// intermediate that disappears with the job, rather than a finished file
  /// already moved to the user's chosen location.
  ///
  /// This is what lets a caller tell "deleting this directory destroys an
  /// artifact a step still claims" from "deleting it is free".
  public func contains(_ url: URL, ofJob job: JobID) -> Bool {
    var directory = jobDirectory(job).standardizedFileURL.path
    if !directory.hasSuffix("/") { directory += "/" }
    return url.standardizedFileURL.path.hasPrefix(directory)
  }

  /// Launch sweep of the `jobs/` temp root. Nothing in it can ever be reused,
  /// so there is no case to reason about and no way for a power loss to leak
  /// tens of gigabytes.
  ///
  /// - Important: scoped to `jobs/`, never `root`. `root` is
  ///   `~/Library/Caches/<bundle-id>` — everything else the app caches there
  ///   belongs to somebody else and must survive launch.
  public func removeAll() {
    try? FileManager.default.removeItem(at: jobsRoot)
  }
}
