import Foundation

/// Routes workspace removal failures into durable logs. Synchronous methods keep teardown from
/// introducing actor suspension points that could reorder queue operations.
struct TeardownJournal: Sendable {
  private let workspace: Workspace

  init(workspace: Workspace) {
    self.workspace = workspace
  }

  // MARK: - Teardown reporting

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

  /// Before assembly writes, remove re-fetched media and rendered chat from this job's
  /// workspace to reduce peak disk use. Retained pieces/audio remain assembly inputs; keep chat
  /// JSON too. Never remove artifacts already delivered outside the workspace.
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

  /// Records step cleanup failures in `StepLog`, which survives `removeStep`. Fire-and-forget
  /// preserves synchronous teardown. A later job cleanup may precede the write, recreating a
  /// log containing only the failure.
  private func recordStepTeardownFailure(_ failed: [URL], job: JobID, step: StepID) {
    guard !failed.isEmpty else { return }
    let workspace = self.workspace
    Task {
      let log = StepLog(fileURL: workspace.logFile(job: job, step: step))
      await log.append("[teardown] could not remove: " + failed.map(\.path).joined(separator: ", "))
      await log.close()
    }
  }

  /// Records job/resume/spent-input cleanup failures outside both removable trees so the log
  /// survives teardown and launch sweeps. Synchronous I/O preserves callers' teardown ordering.
  func record(_ failed: [URL], context: String) {
    guard !failed.isEmpty else { return }

    let timestamp = ISO8601DateFormatter().string(from: Date())
    let line = "\(timestamp) \(context) — could not remove: "
      + failed.map(\.path).joined(separator: ", ") + "\n"
    guard let data = line.data(using: .utf8) else { return }

    // Use the throwing `write(contentsOf:)`; `write(_:)` can raise an uncaught Objective-C
    // exception on disk failure.
    let log = workspace.teardownFailureLog
    if let handle = try? FileHandle(forWritingTo: log) {
      defer { try? handle.close() }
      // Do not write after a failed seek: offset zero would overwrite existing history.
      guard (try? handle.seekToEnd()) != nil else { return }
      try? handle.write(contentsOf: data)
    } else if !FileManager.default.fileExists(atPath: log.path) {
      // Create only when absent. An open failure can mean permissions, and `createFile` would
      // truncate an existing log.
      try? FileManager.default.createDirectory(
        at: log.deletingLastPathComponent(), withIntermediateDirectories: true)
      FileManager.default.createFile(atPath: log.path, contents: data)
      return
    } else {
      return
    }

    compactTeardownFailureLogIfNeeded()
  }

  /// Bounds the cross-launch failure log. This stateless writer checks actual file size rather
  /// than maintaining a byte counter.
  private func compactTeardownFailureLogIfNeeded() {
    let log = workspace.teardownFailureLog
    let cap = StepLog.defaultMaxBytes

    // Compact only well past the cap to avoid rewriting on every append.
    guard
      let data = try? Data(contentsOf: log),
      data.count > cap + cap / 2
    else { return }

    // Trim whole lines so the first retained entry remains readable.
    let text = String(decoding: data, as: UTF8.self)
    var kept = Substring(text)
    while kept.utf8.count > cap, let newline = kept.firstIndex(of: "\n") {
      kept = kept[kept.index(after: newline)...]
    }
    try? Data(kept.utf8).write(to: log, options: .atomic)
  }
}
