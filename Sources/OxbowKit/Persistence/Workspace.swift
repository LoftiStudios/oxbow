import Foundation

/// Owns per-job scratch space so intermediates survive between steps. Parent-managed cleanup
/// also works when a killed helper never runs its `finally` block.
public struct Workspace: Sendable {
  public let root: URL

  public init(root: URL) {
    self.root = root
  }

  /// Only this subtree is reclaimed at launch; retained resume state lives beside it.
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

  /// Retained composites live beside `jobsRoot`, outside the unconditional launch sweep.
  public var resumeRoot: URL {
    root.appending(path: "resume")
  }

  public func resumeDirectory(_ job: JobID) -> URL {
    resumeRoot.appending(path: job.rawValue.uuidString)
  }

  @discardableResult
  public func prepareResume(job: JobID) throws -> URL {
    let directory = resumeDirectory(job)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
  }

  /// Cleared after delivery, job removal, or the piece limit—not at launch. Returns removal
  /// failures.
  @discardableResult
  public func removeResumable(_ job: JobID) -> [URL] {
    removeTree(at: resumeDirectory(job))
  }

  /// Logs live under the job, outside step directories, so `removeStep` cannot erase failure
  /// diagnostics.
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

  /// Removes job scratch space regardless of process outcome. Returns failures; empty means
  /// gone or never present.
  @discardableResult
  public func removeStep(job: JobID, step: StepID) -> [URL] {
    removeTree(at: stepDirectory(job: job, step: step))
  }

  /// Returns removal failures; other entries are still removed.
  @discardableResult
  public func removeJob(_ job: JobID) -> [URL] {
    removeTree(at: jobDirectory(job))
  }

  /// Whether a file is an intermediate inside this job's workspace. Excludes delivered files
  /// and retained resume pieces, which outlive workspace cleanup.
  public func contains(_ url: URL, ofJob job: JobID) -> Bool {
    var directory = jobDirectory(job).standardizedFileURL.path
    if !directory.hasSuffix("/") { directory += "/" }
    return url.standardizedFileURL.path.hasPrefix(directory)
  }

  /// Cleanup-failure log outside jobs and resume trees so it survives teardown and launch
  /// sweeps.
  public var teardownFailureLog: URL {
    root.appending(path: "teardown-failures.log")
  }

  /// Removes entries individually so one failure does not prevent cleanup of the rest; returns
  /// survivors. Missing paths succeed. Symlinks, including the root argument, are unlinked as
  /// leaves and never followed outside the workspace.
  private func removeTree(at directory: URL) -> [URL] {
    // Inspect links before `fileExists`, which follows targets and misses dangling links.
    if (try? FileManager.default.destinationOfSymbolicLink(atPath: directory.path)) != nil {
      do {
        try FileManager.default.removeItem(at: directory)
        return []
      } catch {
        return [directory]
      }
    }

    guard FileManager.default.fileExists(atPath: directory.path) else { return [] }

    guard let entries = try? FileManager.default.contentsOfDirectory(
      at: directory, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey])
    else {
      // If listing fails, try direct removal: the path may be a regular file. Permission
      // failures still surface.
      if (try? FileManager.default.removeItem(at: directory)) != nil { return [] }
      return [directory]
    }

    var failures: [URL] = []
    for entry in entries {
      let values = try? entry.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
      // Check symlinks first so directory links are never traversed.
      let isSymlink = values?.isSymbolicLink == true
      let isDirectory = !isSymlink && values?.isDirectory == true
      if isDirectory {
        let childFailures = removeTree(at: entry)
        guard childFailures.isEmpty else {
          // Report the failed child rather than duplicate it as a nonempty-parent failure.
          failures += childFailures
          continue
        }
        continue
      }
      do {
        try FileManager.default.removeItem(at: entry)
      } catch {
        failures.append(entry)
      }
    }

    guard failures.isEmpty else { return failures }

    do {
      try FileManager.default.removeItem(at: directory)
      return []
    } catch {
      return [directory]
    }
  }

  /// Launch cleanup is confined to `jobs/`; resume state and other Application Support data
  /// must survive. The OS does not purge this directory as a cache.
  public func removeAll() {
    try? FileManager.default.removeItem(at: jobsRoot)
  }
}
