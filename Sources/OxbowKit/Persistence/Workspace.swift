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

  /// The only subtree of `root` the launch sweep may reclaim. Scoped
  /// deliberately: `root` is the app's whole cache directory, so the sweep
  /// is confined here and cannot touch `resumeRoot`, where partial composites
  /// are retained across launches.
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

  /// Partial composites, retained across launches so a failed encode can be
  /// continued rather than restarted.
  ///
  /// Deliberately a sibling of `jobsRoot`, never inside it. `removeAll()` is
  /// unconditional and its value is that it *cannot be wrong*; putting
  /// resumable state inside `jobs/` would force it to become a rule that can
  /// be. See docs/design/resume.md §3.
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

  /// Cleared on successful delivery, on job removal, and when the piece cap
  /// is hit. Never at launch — that is the point.
  ///
  /// Returns whatever could not be removed — see `removeTree`.
  @discardableResult
  public func removeResumable(_ job: JobID) -> [URL] {
    removeTree(at: resumeDirectory(job))
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
  ///
  /// Returns whatever could not be removed. Empty means the directory is
  /// genuinely gone (or was never there, which is not a failure).
  @discardableResult
  public func removeStep(job: JobID, step: StepID) -> [URL] {
    removeTree(at: stepDirectory(job: job, step: step))
  }

  /// Returns whatever could not be removed — see `removeTree`'s doc comment
  /// for why a single stubborn file no longer costs the rest of the job's
  /// workspace, and why this reports rather than staying silent about it.
  @discardableResult
  public func removeJob(_ job: JobID) -> [URL] {
    removeTree(at: jobDirectory(job))
  }

  /// True when `url` names a file inside this job's workspace — i.e. an
  /// intermediate that disappears with the job, rather than a finished file
  /// already moved to the user's chosen location.
  ///
  /// This is what lets a caller tell "deleting this directory destroys an
  /// artifact a step still claims" from "deleting it is free".
  ///
  /// - Important: a file in `resumeRoot` reports `false` here, and that is
  ///   deliberate rather than incidental. `contains` means "an intermediate
  ///   that dies with the job workspace"; a retained piece outlives it by
  ///   design. Do not "fix" this to include the resume area.
  public func contains(_ url: URL, ofJob job: JobID) -> Bool {
    var directory = jobDirectory(job).standardizedFileURL.path
    if !directory.hasSuffix("/") { directory += "/" }
    return url.standardizedFileURL.path.hasPrefix(directory)
  }

  /// Where a job- or resumable-level teardown failure gets recorded once
  /// `TeardownJournal` sees one — see its use of this.
  ///
  /// A sibling of `jobsRoot` and `resumeRoot`, deliberately never inside
  /// either. `removeJob` deletes a job's own `logs/` directory as part of
  /// what it tears down, so nothing under `jobsRoot` can be where a
  /// job-level failure survives being reported — and `removeAll()`'s launch
  /// sweep is scoped to `jobsRoot` alone, so this file outlives that sweep
  /// too. It is meant to accumulate: one entry might be a fluke, but a file
  /// that keeps growing is evidence of a real, reproducible fault.
  public var teardownFailureLog: URL {
    root.appending(path: "teardown-failures.log")
  }

  /// Removes `directory` and everything under it, one item at a time, and
  /// returns whatever survived instead of throwing away that information.
  ///
  /// A single recursive `FileManager.removeItem` deletes depth-first and
  /// aborts at the very first failure it hits — which is exactly how an
  /// 8.66 GB video once survived a job's teardown while everything after it
  /// silently vanished: the removal reached that one undeletable file,
  /// threw, and stopped, with no record that it had. Doing it one entry at
  /// a time means a stubborn file only costs itself.
  ///
  /// An empty result means `directory` is genuinely gone. `directory` never
  /// having existed counts as that, not as a failure — there is nothing
  /// there to fail to remove.
  ///
  /// A symlink anywhere in the tree — including at `directory` itself — is
  /// always a leaf: unlinked, never followed. Nothing we or the helper write
  /// into a job's workspace ever creates one, but deletion here must never be
  /// able to widen beyond a job's own workspace by walking out through a
  /// link, so this does not lean on `isDirectoryKey` alone to keep that true.
  private func removeTree(at directory: URL) -> [URL] {
    // `destinationOfSymbolicLink` inspects `directory` itself (lstat), unlike
    // `fileExists`, which follows a symlink to its target (stat) — so a
    // dangling symlink here would fail `fileExists` and read as "nothing to
    // remove" while the broken link itself was left behind. Checking this
    // first catches that case too, before the `fileExists` guard below ever
    // runs.
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
      // Listing can fail for a permissions problem on a genuine directory,
      // but also whenever `directory` is not a directory at all — most often
      // a regular file. Removing it directly resolves the second case
      // instead of misreporting "could not list" for something that was
      // never a directory to begin with; a real permissions problem fails
      // `removeItem` the same way it failed `contentsOfDirectory`, so this
      // does not paper over that one.
      if (try? FileManager.default.removeItem(at: directory)) != nil { return [] }
      return [directory]
    }

    var failures: [URL] = []
    for entry in entries {
      let values = try? entry.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
      // Checked ahead of `isDirectoryKey` and short-circuits it: a symlink is
      // a leaf even when it points at a directory, so this must never fall
      // into the recursive branch below for one.
      let isSymlink = values?.isSymbolicLink == true
      let isDirectory = !isSymlink && values?.isDirectory == true
      if isDirectory {
        let childFailures = removeTree(at: entry)
        guard childFailures.isEmpty else {
          // `entry` is a non-empty directory because something inside it
          // failed; the failure already in hand names the real cause, so
          // attempting `removeItem` on `entry` itself would just report the
          // same underlying problem a second time under a different path.
          failures += childFailures
          continue
        }
        // Everything inside was removed; the recursive call above already
        // took `entry` itself with it, so there is nothing left to do here.
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

  /// Launch sweep of the `jobs/` temp root. Nothing in it can ever be reused,
  /// so there is no case to reason about and no way for a power loss to leak
  /// tens of gigabytes.
  ///
  /// - Important: scoped to `jobs/`, never `root`. `root` is a `workspace`
  ///   directory under `~/Library/Application Support/<bundle-id>`
  ///   (`Oxbow/AppComposition.swift`) — Application Support, not Caches. That
  ///   distinction matters: unlike a cache, it is backed up and never purged
  ///   by the OS on its own, so everything else the app keeps there belongs
  ///   to somebody else and must survive launch regardless.
  public func removeAll() {
    try? FileManager.default.removeItem(at: jobsRoot)
  }
}
