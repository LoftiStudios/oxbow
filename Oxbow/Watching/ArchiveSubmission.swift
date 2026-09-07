import Foundation
import OxbowKit

/// Queues a watched channel's archives using that channel's frozen settings.
///
/// **One function, three triggers**: adding a channel with backfill and
/// automatic downloading on, clicking a finding, and a sweep finding something
/// new. All three mean the same thing — "queue this with the settings this
/// channel already has" — and before this existed each of them did it
/// differently. Adding a channel wrote a file and waited for a poll; a
/// finding row opened a prefilled form the person had already filled in once
/// as channel settings; only the sweep actually submitted, into a `catch` that
/// discarded whatever went wrong.
///
/// **Every refusal comes back, none are swallowed.** `IntentSubmission
/// .Failure` already carries a sentence fit to show a person — an
/// unrecognised link, a composite whose chat cannot be built, a refusal from
/// intake itself — and `WatchPoller` used to throw all of it away. A failure
/// that nobody can see is indistinguishable from a feature that does not
/// work, which is precisely how this feature read.
@MainActor
enum ArchiveSubmission {

  /// What one batch did. Both halves are needed: `queued` is what the caller
  /// marks seen, `failures` is what it has to show.
  struct Result {
    /// Archives that reached the queue — `.queued` and `.alreadyQueued`
    /// alike, since both mean the archive is accounted for.
    var queued: [ChannelArchive] = []

    /// Why each archive that did not reach the queue did not, keyed by
    /// archive id and phrased for a person.
    var failures: [String: String] = [:]

    var isEmpty: Bool { queued.isEmpty && failures.isEmpty }
  }

  /// Submits `archives` in order, one at a time.
  ///
  /// Sequential rather than concurrent, matching `WatchPoll.sweep`'s own
  /// reasoning: `QueueEngine` serialises the downloads anyway, so parallel
  /// submission would buy a burst of metadata requests and nothing else.
  ///
  /// **Marks nothing seen.** Each caller owns a different `WatchStore` and
  /// has its own discipline for writing through it — `WatchPoller` re-reads
  /// immediately before writing, because a submission's metadata fetch is a
  /// suspension point across which the Watching pane's own writers run. That
  /// belongs with the caller, not here.
  static func submit(
    _ archives: [ChannelArchive], for watch: Watch, into controller: QueueController
  ) async -> Result {
    var result = Result()
    for archive in archives {
      do {
        _ = try await IntentSubmission.submit(
          link: archive.id,
          quality: watch.settings.qualityCap,
          output: watch.settings.output,
          chatSize: watch.settings.chatSize,
          destination: watch.settings.destination,
          // Re-read per archive rather than captured once: each submission
          // adds a job, and the duplicate guard inside `submit` has to see
          // the one its predecessor just made.
          existingJobs: controller.jobs,
          into: IntakeModel(controller: controller))
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
