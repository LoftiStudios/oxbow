import Foundation
import OxbowKit

/// Shared submission path for manual findings, automatic sweeps, and initial backfill, using
/// frozen watch settings. Return every refusal for the caller to display.
@MainActor
enum ArchiveSubmission {

  /// Return queued archives for marking seen and failures for display.
  struct Result {
    /// Both newly queued and already-queued archives count as handled.
    var queued: [ChannelArchive] = []

    /// Why each archive that did not reach the queue did not, keyed by
    /// archive id and phrased for a person.
    var failures: [String: String] = [:]

    var isEmpty: Bool { queued.isEmpty && failures.isEmpty }
  }

  /// Submit sequentially. Callers own seen-state updates and must re-read around metadata
  /// awaits. Successful submissions record through QueueHost's resolved handle, which is nil
  /// during hosted tests.
  static func submit(
    _ archives: [ChannelArchive], for watch: Watch, into controller: QueueController
  ) async -> Result {
    let recording = QueueHost.shared.videoRecording
    var result = Result()
    for archive in archives {
      do {
        _ = try await IntentSubmission.submit(
          link: archive.id,
          quality: watch.settings.qualityCap,
          output: watch.settings.output,
          chatSize: watch.settings.chatSize,
          destination: watch.settings.destination,
          // Re-read jobs per archive so duplicate checks include earlier submissions in this
          // batch.
          existingJobs: controller.jobs,
          into: IntakeModel(controller: controller),
          recording: recording)
        result.queued.append(archive)
      } catch let failure as IntentSubmission.Failure {
        result.failures[archive.id] = String(localized: failure.localizedStringResource)
      } catch {
        result.failures[archive.id] = error.localizedDescription
      }
    }
    return result
  }
}
