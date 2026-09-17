import AppKit
import Foundation
import Observation
import OxbowKit

/// Republish QueueEngine snapshots on the main actor for SwiftUI.
@MainActor
@Observable
final class QueueController {

  private(set) var jobs: [Job] = []
  /// Set when `start()` fails. The queue is unusable; the UI says why.
  private(set) var startFailure: String?

  /// Notify Dock and notification observers after updating jobs, using the same snapshot as the
  /// window.
  var onSnapshot: (([Job]) -> Void)?

  /// Signal a new enqueue separately from startup snapshots containing restored jobs.
  var onEnqueue: (() -> Void)?

  private let engine: QueueEngine
  /// Use the helper path resolved by AppComposition.
  private let helperExecutable: URL
  private let makeProcess: @Sendable () -> HelperProcessing
  private var observation: Task<Void, Never>?

  init(configuration: QueueEngine.Configuration) {
    engine = QueueEngine(configuration: configuration)
    helperExecutable = configuration.helperExecutable
    makeProcess = configuration.makeProcess
  }

  func start() async {
    // makeSnapshots registers and yields current state in one actor turn, so it need not race
    // startup.
    observation = Task { [engine] in
      for await snapshot in await engine.makeSnapshots() {
        jobs = snapshot
        onSnapshot?(snapshot)
      }
    }

    // Load screenshot fixtures without running their fictional jobs.
    #if DEBUG
    let runsWork = ScreenshotFixture.directory == nil
    #else
    let runsWork = true
    #endif

    do {
      try await engine.start(runsWork: runsWork)
    } catch {
      startFailure = "The saved queue could not be loaded: \(error.localizedDescription)"
    }
  }

  /// On termination, cancel helpers and flush the pending save before exiting.
  func shutDown() async { await engine.shutDown() }

  /// Fetch metadata outside the queue, sharing fetchInfoDetailed's path without returning the
  /// raw payload.
  func fetchInfo(for id: String) async throws -> VideoInfo {
    try await fetchInfoDetailed(for: id).info
  }

  /// Return parsed metadata and the raw payload from one info run. Fetching does not persist
  /// anything; record only after submission.
  func fetchInfoDetailed(for id: String) async throws -> VideoInfoFetcher.Fetched {
    // Fixture metadata has no real helper payload; return an empty payload rather than
    // fabricate one.
    #if DEBUG
    if let canned = ScreenshotFixture.videoInfo(for: id) {
      return VideoInfoFetcher.Fetched(info: canned, payload: "")
    }
    #endif
    return try await VideoInfoFetcher.fetchDetailed(
      id: id, helper: helperExecutable, process: makeProcess())
  }

  /// Await engine admission before returning so intake can safely dismiss. Intake owns template
  /// construction.
  func enqueue(_ template: JobTemplate, title: String) async {
    await engine.enqueue(template, title: title)
    onEnqueue?()
  }

  /// The tail of a step's captured helper output, for the detail disclosure.
  func log(for step: StepID) async -> String? { await engine.log(for: step) }

  /// Measure job retention on demand; it is user-cleared filesystem state rather than a
  /// snapshot field.
  func retainedBytes(for job: JobID) async -> Int { await engine.retainedBytes(forJob: job) }

  /// Return retained pieces, a delivered file, or nothing. Check once for menu state and again
  /// on activation to avoid stale reveal targets.
  func revealTarget(for job: JobID) async -> RevealTarget? {
    await engine.revealTarget(forJob: job)
  }

  /// Reveals whatever the composite step's Finder-reveal item currently
  /// points at — never the job workspace, which also holds the download and
  /// the chat render. docs/design/fragmented-output.md §6.
  func revealRetainedFiles(for job: JobID) async {
    switch await engine.revealTarget(forJob: job) {
    case .retained(let directory, let pieces):
      NSWorkspace.shared.activateFileViewerSelecting(pieces.isEmpty ? [directory] : pieces)
    case .delivered(let file):
      NSWorkspace.shared.activateFileViewerSelecting([file])
    case nil:
      break
    }
  }

  /// Remove queue state and workspace files after stopping helpers. Preserve delivered files.
  func remove(jobs ids: Set<JobID>) async { await engine.remove(jobs: ids) }

  func cancel(job id: JobID) async { await engine.cancel(job: id) }
  func cancel(step id: StepID) async { await engine.cancel(step: id) }
  func retry(step id: StepID) async { await engine.retry(step: id) }

  /// Retries every unfinished step of a job — what Retry means on a row, as
  /// opposed to on one step of an expanded job.
  func retry(job id: JobID) async { await engine.retry(job: id) }
}
