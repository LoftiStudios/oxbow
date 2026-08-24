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
    // Observe before starting, so no snapshot from `start()` is missed.
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

  func enqueueVideo(urlText: String, destination: URL) throws {
    guard let videoID = TwitchVideoURL.videoID(from: urlText) else {
      throw IntakeError.notAVideoURL
    }

    // An empty quality means best available - see ArgumentBuilder.
    let request = VideoRequest(videoID: videoID, quality: "", destination: destination)
    let engine = engine
    Task { await engine.enqueue(.video(request), title: "Video \(videoID)") }
  }

  func cancel(job id: JobID) async { await engine.cancel(job: id) }
  func cancel(step id: StepID) async { await engine.cancel(step: id) }
  func retry(step id: StepID) async { await engine.retry(step: id) }
}
