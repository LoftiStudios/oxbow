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

  enum IntakeError: Error, Equatable {
    case notAVideoURL
  }

  private(set) var jobs: [Job] = []
  /// Set when `start()` fails. The queue is unusable; the UI says why.
  private(set) var startFailure: String?

  private let engine: QueueEngine
  private var observation: Task<Void, Never>?

  init(configuration: QueueEngine.Configuration) {
    engine = QueueEngine(configuration: configuration)
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
      }
    }

    do {
      try await engine.start()
    } catch {
      startFailure = "The saved queue could not be loaded: \(error.localizedDescription)"
    }
  }

  /// Forwards to `QueueEngine.shutDown()`. Call on app termination: it kills
  /// the running helpers before the app exits — otherwise they outlive it as
  /// orphans — and writes the pending debounced save.
  func shutDown() async { await engine.shutDown() }

  func enqueueVideo(urlText: String, destination: URL) throws {
    guard case .video(let videoID) = TwitchLink.parse(urlText) else {
      throw IntakeError.notAVideoURL
    }

    // An empty quality means best available - see ArgumentBuilder.
    let request = VideoRequest(videoID: videoID, quality: "", destination: destination)
    let engine = engine
    Task { await engine.enqueue(JobTemplate(media: .video(request)), title: "Video \(videoID)") }
  }

  /// The tail of a step's captured helper output, for the detail disclosure.
  func log(for step: StepID) async -> String? { await engine.log(for: step) }

  func cancel(job id: JobID) async { await engine.cancel(job: id) }
  func cancel(step id: StepID) async { await engine.cancel(step: id) }
  func retry(step id: StepID) async { await engine.retry(step: id) }
}
