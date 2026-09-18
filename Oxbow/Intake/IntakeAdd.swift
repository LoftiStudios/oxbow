import Foundation
import OxbowKit

/// Shared enqueue-and-record path for the intake and intents. Stores stay outside IntakeModel
/// so per-keystroke metadata fetches cannot persist unsubmitted videos. See
/// docs/design/video-record.md §7.
@MainActor
enum IntakeAdd {

  /// Enqueues the job and records its fetch on success. Nil `recording` disables persistence;
  /// nil `helperVersion` permits facts but no raw payload. Do not suspend between enqueue
  /// returning and recording: main-actor writers must update videos.json without interleaving.
  @discardableResult
  static func perform(
    _ model: IntakeModel,
    recording: VideoRecording?,
    helperVersion: String?) async -> Bool
  {
    guard await model.add() else { return false }

    // Use the id assigned with `lastFetch` under the generation guard, not the current link
    // text. Record facts and queued state together so the next watch sweep treats the video as
    // handled.
    if let recording, let fetched = model.lastFetch, let id = model.metadataIdentifier {
      VideoRecorder.record(
        fetched,
        for: id,
        helperVersion: helperVersion,
        records: recording.records,
        payloads: recording.payloads)
    }
    return true
  }
}
