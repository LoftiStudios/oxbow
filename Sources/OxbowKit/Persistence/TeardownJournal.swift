import Foundation

/// Tears down workspace directories and makes sure a failure to do so is
/// recorded somewhere it survives.
///
/// **The only caller of `Workspace`'s three removal methods.** Those methods
/// return whatever they could not remove rather than discarding it, and this
/// type is what guarantees every one of those returns is looked at — the
/// engine used to promise the same thing in a comment, which made it a
/// discipline each call site had to remember rather than a property of the
/// code. Routing all three through one type is what makes it structural.
///
/// A `Sendable` struct over an immutable `Workspace`, so it has no isolation
/// of its own and every method stays synchronous. That is deliberate: the
/// engine calls these from synchronous teardown paths (`completeStep`,
/// `abandonAlreadyFinalizedStep`, `removeJobWorkspace`), and making any of
/// them `async` would introduce suspension points that reorder work inside
/// those paths.
struct TeardownJournal: Sendable {
  private let workspace: Workspace

  init(workspace: Workspace) {
    self.workspace = workspace
  }

  // MARK: - Teardown reporting
  //
  // `Workspace`'s removal methods no longer discard what they fail to
  // remove — see their doc comments. These three wrappers are the only
  // callers of those methods anywhere in OxbowKit, so every workspace
  // teardown is guaranteed to have somewhere to report a failure, rather
  // than that being a discipline each call site has to remember on its own.
  // That is the fix for the actual incident this exists to prevent: an
  // 8.66 GB video that outlived its job's teardown with nothing anywhere
  // recording that the removal had failed.

  /// Tears down a step's own working directory and reports anything left
  /// behind in that step's transcript — see `recordStepTeardownFailure`.
  func removeStep(job: JobID, step: StepID) {
    recordStepTeardownFailure(
      workspace.removeStep(job: job, step: step), job: job, step: step)
  }

  /// Tears down a job's whole workspace and reports anything left behind —
  /// see `record`.
  func removeJob(_ id: JobID) {
    record(
      workspace.removeJob(id), context: "job \(id.rawValue.uuidString): workspace")
  }

  /// Tears down a job's retained-pieces area and reports anything left
  /// behind — see `record`.
  func removeResumable(_ id: JobID) {
    record(
      workspace.removeResumable(id),
      context: "job \(id.rawValue.uuidString): resumable area")
  }

  /// Drops the inputs an `.assemble` step has just made dead: the re-fetched
  /// video (or clip) and the chat render.
  ///
  /// Both can go once the pieces and the sidecar audio exist, because the
  /// audio was copied out on the first attempt — resume.md §4. Dropping them
  /// at this moment rather than at job end is what keeps the recovery peak
  /// near a normal run's: §5's table has the delivered file growing against
  /// 29.4 GB rather than 55.9. So the call belongs *before* assemble's FFmpeg
  /// starts writing, which is why `QueueEngine.launch` makes it there.
  ///
  /// The chat transcript and the composite's own pieces are deliberately not
  /// spent — the pieces are half the delivery, and the transcript is small
  /// enough that dropping it buys nothing.
  ///
  /// The one removal here that does not go through `Workspace`, because it
  /// takes individual files rather than a tree. `contains(_:ofJob:)` is what
  /// keeps that safe: a step's `artifact` can point outside the workspace
  /// once `move` has delivered it, and a delivered file is the one thing
  /// this must never touch.
  func removeSpentInputs(of job: Job) {
    let spent = job.steps.compactMap { step -> URL? in
      switch step.kind {
      case .downloadVideo, .downloadClip, .renderChat: step.artifact
      case .downloadChat, .composite, .assemble: nil
      }
    }
    let unremoved = spent
      .filter { workspace.contains($0, ofJob: job.id) }
      .compactMap { file -> URL? in
        do {
          try FileManager.default.removeItem(at: file)
          return nil
        } catch {
          return file
        }
      }
    record(
      unremoved, context: "job \(job.id.rawValue.uuidString): re-fetched inputs spent by assemble")
  }

  /// Writes a step-level teardown failure into that step's own `StepLog` —
  /// the file already meant to hold "why did this go wrong" for exactly
  /// this step, and, unlike a job-level failure, one that is still standing
  /// when this runs: `removeStep` only ever touches the step's own working
  /// directory (`stepDirectory`), never `logs/`. That directory — and this
  /// step's slice of it — survives until the whole job's workspace goes
  /// with `removeJob`, so the row someone would already open to ask what
  /// went wrong is where this shows up.
  ///
  /// Fire-and-forget: `StepLog.append` is `async`, actor-isolated to
  /// `StepLog` itself rather than to `QueueEngine`, and the engine's
  /// teardown paths that reach this (`completeStep`,
  /// `abandonAlreadyFinalizedStep`) are synchronous and must not become
  /// `async` just to report a failure that changes no queue state. Nothing
  /// here races anything that matters:
  /// `removeStep` never touches this file, and the one interleaving that
  /// could happen — a job-level teardown deleting `logs/` before this write
  /// lands — just recreates a single-entry `logs/` for a job that is
  /// already gone, which is itself more evidence, not corruption.
  private func recordStepTeardownFailure(_ failed: [URL], job: JobID, step: StepID) {
    guard !failed.isEmpty else { return }
    let workspace = self.workspace
    Task {
      let log = StepLog(fileURL: workspace.logFile(job: job, step: step))
      await log.append("[teardown] could not remove: " + failed.map(\.path).joined(separator: ", "))
      await log.close()
    }
  }

  /// Records a job- or resumable-area teardown failure, or a failure
  /// dropping assemble's spent inputs, somewhere it survives being
  /// reported. Those three have no per-step home the way a step-level
  /// failure does: `removeJob` takes the job's own `logs/` directory down
  /// with it as part of what it tears down, and the assemble-time cleanup
  /// runs once per job rather than once per step. This writes instead to
  /// `Workspace.teardownFailureLog`, a small file that sits beside `jobs/`
  /// and `resume/` — neither `removeJob` nor the launch sweep
  /// (`removeAll()`, scoped to `jobsRoot`) can ever reach it, so it
  /// outlives every failure it records and accumulates across launches.
  ///
  /// Plain synchronous method, deliberately: `TeardownJournal` is a
  /// `Sendable` struct over an immutable `Workspace`, with no isolation
  /// domain of its own, and this does nothing but synchronous file I/O
  /// against an immutable path. That is what lets actor-isolated callers —
  /// the engine's teardown paths among them — call it directly, no `await`
  /// required.
  func record(_ failed: [URL], context: String) {
    guard !failed.isEmpty else { return }

    let timestamp = ISO8601DateFormatter().string(from: Date())
    let line = "\(timestamp) \(context) — could not remove: "
      + failed.map(\.path).joined(separator: ", ") + "\n"
    guard let data = line.data(using: .utf8) else { return }

    // `FileHandle.write(_:)` (no `contentsOf:`) can raise an uncaught
    // Objective-C exception on a genuine write failure rather than
    // returning a Swift error — exactly the kind of failure a full disk
    // would produce, which is also a plausible companion to a teardown
    // failure. `write(contentsOf:)` is the throwing form, so a failure here
    // is just another swallowed `try?` rather than a crash compounding the
    // problem this method exists to report.
    let log = workspace.teardownFailureLog
    if let handle = try? FileHandle(forWritingTo: log) {
      defer { try? handle.close() }
      // A failed seek must not fall through to the write below: opening for
      // writing does not itself seek, so that write would land at offset 0
      // and overwrite every entry already accumulated here — destroying the
      // history this file exists to keep, in exchange for recording the one
      // failure that triggered it.
      guard (try? handle.seekToEnd()) != nil else { return }
      try? handle.write(contentsOf: data)
    } else if !FileManager.default.fileExists(atPath: log.path) {
      // Reached only when the file genuinely does not exist yet.
      // `FileHandle(forWritingTo:)` can also fail to open a file that *does*
      // exist — a permissions problem, say — and `createFile(atPath:contents:)`
      // truncates, so falling through to it unconditionally would silently
      // wipe an existing log the moment opening it started failing for any
      // reason, not only the reason this branch is for.
      try? FileManager.default.createDirectory(
        at: log.deletingLastPathComponent(), withIntermediateDirectories: true)
      FileManager.default.createFile(atPath: log.path, contents: data)
      return
    } else {
      return
    }

    compactTeardownFailureLogIfNeeded()
  }

  /// Bounds `teardownFailureLog` the way `StepLog` bounds its own file — see
  /// its doc comment — because this file has the same problem and no
  /// dedicated owner to solve it a different way: it sits outside the launch
  /// sweep (`Workspace.removeAll()` is scoped to `jobsRoot`) and nothing else
  /// reads or rotates it, so an unbounded accumulation across launches is not
  /// a policy, just an oversight.
  ///
  /// Unlike `StepLog`, there is no persistent actor here to track a running
  /// byte count between writes — this is a plain method on a stateless
  /// struct, called once per failure — so this checks the file's actual
  /// size instead. A failed teardown is rare enough that re-reading a
  /// capped-size file on each one costs nothing that matters.
  private func compactTeardownFailureLogIfNeeded() {
    let log = workspace.teardownFailureLog
    let cap = StepLog.defaultMaxBytes

    // Compact only when meaningfully over, not the instant the cap is
    // crossed — same reasoning as `StepLog.append`: rewriting the file on
    // every single write would be needless O(n^2) I/O for what is meant to
    // be an occasional, low-volume file.
    guard
      let data = try? Data(contentsOf: log),
      data.count > cap + cap / 2
    else { return }

    // Drops whole lines, never a byte offset, for the same reason
    // `StepLog.compact()` does: a byte cut could leave a mangled first entry
    // that reads as corruption rather than as "the older history was
    // trimmed".
    let text = String(decoding: data, as: UTF8.self)
    var kept = Substring(text)
    while kept.utf8.count > cap, let newline = kept.firstIndex(of: "\n") {
      kept = kept[kept.index(after: newline)...]
    }
    try? Data(kept.utf8).write(to: log, options: .atomic)
  }
}
