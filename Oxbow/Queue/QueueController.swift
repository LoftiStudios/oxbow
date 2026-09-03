import AppKit
import Foundation
import Observation
import OxbowKit

/// Owns the engine and republishes its snapshots for SwiftUI.
///
/// The engine is an actor, deliberately off the main actor, in a library
/// with no UI dependency — `makeSnapshots()` exists so that observation is
/// somebody else's job. This is that somebody.
@MainActor
@Observable
final class QueueController {

  private(set) var jobs: [Job] = []
  /// Set when `start()` fails. The queue is unusable; the UI says why.
  private(set) var startFailure: String?

  /// Called with every snapshot the engine publishes, after `jobs` is
  /// updated. The Dock and Notification Center read from here rather than
  /// opening a second subscription to the engine, so what they show and what
  /// the window shows can never come from different snapshots.
  var onSnapshot: (([Job]) -> Void)?

  /// Called when a job is admitted to the queue. Distinct from "a snapshot
  /// containing a new job", which is also what launch looks like — see
  /// `docs/design/status.md` §7.2 for why the notifier needs the difference.
  var onEnqueue: (() -> Void)?

  private let engine: QueueEngine
  /// Threaded through from `AppComposition` via `configuration`, rather than
  /// re-derived here, so there is exactly one place that resolves the
  /// bundle's `Contents/MacOS/helper/TwitchDownloaderCLI` path.
  private let helperExecutable: URL
  private let makeProcess: @Sendable () -> HelperProcessing
  private var observation: Task<Void, Never>?

  init(configuration: QueueEngine.Configuration) {
    engine = QueueEngine(configuration: configuration)
    helperExecutable = configuration.helperExecutable
    makeProcess = configuration.makeProcess
  }

  func start() async {
    // Ordering here doesn't matter for correctness: `makeSnapshots()`
    // registers the observer's continuation and yields the current `jobs`
    // in the same actor turn (see QueueEngine.makeSnapshots), so whichever
    // of these two calls reaches the engine first, the observer's first
    // element is always a complete, up-to-date snapshot - never a partial
    // or stale one it would need to have raced `start()` to avoid.
    observation = Task { [engine] in
      for await snapshot in await engine.makeSnapshots() {
        jobs = snapshot
        onSnapshot?(snapshot)
      }
    }

    // A screenshot run loads the fixture and looks at it; it must not try to
    // download the invented video ids in it. See `ScreenshotFixture`.
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

  /// Forwards to `QueueEngine.shutDown()`. Call on app termination: it kills
  /// the running helpers before the app exits — otherwise they outlive it as
  /// orphans — and writes the pending debounced save.
  func shutDown() async { await engine.shutDown() }

  /// Runs the helper's `info` verb directly, outside the queue: this
  /// produces no artifact, is not a step, and must never appear in `jobs`
  /// (design doc §3). Intake calls it once per pasted link, before any job
  /// exists, to derive a filename and offer a quality picker.
  func fetchInfo(for id: String) async throws -> VideoInfo {
    try await VideoInfoFetcher.fetch(id: id, helper: helperExecutable, process: makeProcess())
  }

  /// Enqueues an already-composed template. Intake now builds the whole
  /// `JobTemplate` — parsing the link, resolving destinations per output,
  /// and wiring the toggles — so the controller no longer parses URLs or
  /// constructs requests itself.
  ///
  /// `async`, awaiting the engine, rather than spawning an untracked `Task`:
  /// intake dismisses its sheet on the strength of this call, and a
  /// fire-and-forget enqueue cannot tell the caller whether the job landed.
  /// The failure it invites is the worst kind — the sheet closes, nothing
  /// appears in the queue, and nothing says why. Returning only once the
  /// engine holds the job makes "it is queued" a fact the sheet can act on.
  func enqueue(_ template: JobTemplate, title: String) async {
    await engine.enqueue(template, title: title)
    // After the await, deliberately: same reason this method is `async` at
    // all — a caller must never be told about a job that did not land.
    onEnqueue?()
  }

  /// The tail of a step's captured helper output, for the detail disclosure.
  func log(for step: StepID) async -> String? { await engine.log(for: step) }

  /// Bytes held in a job's retention area, for the failed-row disclosure.
  /// Retention is user-cleared (docs/design/resume.md §8), so the row reads
  /// this on demand rather than carrying it in `Job` — it is a filesystem
  /// fact, not queue state, and stale for exactly as long as a snapshot is.
  func retainedBytes(for job: JobID) async -> Int { await engine.retainedBytes(forJob: job) }

  /// What the composite step's Finder-reveal item should currently show —
  /// retained pieces, the file the job delivered once those pieces are gone,
  /// or nothing. `StepRow` reads this to decide whether the item is enabled;
  /// `revealRetainedFiles` reads it again, fresh, to decide what to select.
  /// See `QueueEngine.revealTarget(forJob:)`.
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
      // The item is disabled in exactly this case, so a click can only
      // reach here through a stale state read; do nothing rather than open
      // a Finder window on nothing.
      break
    }
  }

  /// Forgets these jobs: out of the queue, off disk, helpers killed first if
  /// any were running. Delivered files are never touched — see
  /// `QueueEngine.remove(jobs:)`.
  func remove(jobs ids: Set<JobID>) async { await engine.remove(jobs: ids) }

  func cancel(job id: JobID) async { await engine.cancel(job: id) }
  func cancel(step id: StepID) async { await engine.cancel(step: id) }
  func retry(step id: StepID) async { await engine.retry(step: id) }

  /// Retries every unfinished step of a job — what Retry means on a row, as
  /// opposed to on one step of an expanded job.
  func retry(job id: JobID) async { await engine.retry(job: id) }
}
