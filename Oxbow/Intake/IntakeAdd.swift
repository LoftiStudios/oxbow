import Foundation
import OxbowKit

/// Adds the job an `IntakeModel` has composed, and records what its fetch
/// already paid for.
///
/// **One function because there are two ways to press Add.** A person pastes
/// a link into Add Download and clicks the button; Shortcuts, Spotlight and a
/// watched channel's backfill go through `IntentSubmission.submit`. Both end
/// in `model.add()`, and `docs/design/video-record.md` §3.5 wants both to
/// leave a record behind — a video downloaded by hand today should already be
/// marked downloaded when its channel is added as a watch next month. When
/// only the intent path recorded, that was precisely the case that did not
/// work, and nothing about the two call sites said they were supposed to
/// agree. Now the agreement is the function.
///
/// **The model is read, never written through.** `IntakeModel` holds no
/// `VideoRecordStore`, no `PayloadStore` and no `VideoRecording`, and it must
/// stay that way: `IntakeModel.load()` runs on every debounced keystroke in
/// Add Download, so a model that owned a store would be one editing mistake
/// away from recording every link somebody pasted and thought better of. The
/// dependency points this way round — the adder reads `lastFetch` off the
/// model — so the per-keystroke path has no write surface at all, which is a
/// stronger guarantee than a test that it does not use one.
@MainActor
enum IntakeAdd {

  /// Enqueues `model`'s composed job, and on success records its fetch into
  /// `recording`.
  ///
  /// Returns whether the job landed, exactly as `IntakeModel.add()` does, so
  /// both callers keep their own refusal handling: the window stays open on
  /// `model.addFailure`, the intent throws it.
  ///
  /// `recording` is `nil` for "record nothing", which is the case for a
  /// non-user session — `QueueHost.videoRecording` is nil under `xcodebuild
  /// test`, so a test run cannot write the developer's own `videos.json` —
  /// and for a fetch that never produced anything. `helperVersion` is passed
  /// in rather than read from `AboutInfo.main` here so that a test can supply
  /// a known stamp; it is legitimately nil in a build with no embedded helper,
  /// and `VideoRecorder` then writes the facts without a payload rather than
  /// stamping a payload with a guess.
  ///
  /// **No `await` between the enqueue and the record**, and that is load
  /// bearing rather than incidental: `videos.json` has four writers that are
  /// safe against each other only because each does its load-modify-save on
  /// the main actor with no suspension point in between. See `VideoRecorder`.
  /// It is also what makes the `queued` state below unambiguous: nothing else
  /// on the main actor — a job that finished while `add()` was suspended, say
  /// — can land between the enqueue returning and the state being written.
  @discardableResult
  static func perform(
    _ model: IntakeModel,
    recording: VideoRecording?,
    helperVersion: String?) async -> Bool
  {
    guard await model.add() else { return false }

    // The id comes from `metadataIdentifier` rather than from the link text,
    // because `metadataIdentifier` and `lastFetch` are assigned together
    // inside `load()`'s `issued == generation` guard. Taking both from the
    // same assignment is what makes it impossible to file one video's payload
    // under another video's id; re-parsing `model.linkText` here would be a
    // second, independent answer to a question that already has one.
    //
    // This is also where a video becomes `queued`, and that write is the
    // reason both routes have to come through here rather than each calling
    // `model.add()` for itself. `WatchState.countsAsSeen` reads `queued` as
    // handled, and it is the whole seen-set (`docs/design/video-record.md`
    // §3.2, §7) — so a route that submitted without recording the state would
    // leave its archive looking untouched to the next sweep and have it
    // downloaded a second time while the first download was still running.
    // `VideoRecorder.record` writes the facts and the state in one
    // load-modify-save; see its own doc comment for why they are not two.
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
