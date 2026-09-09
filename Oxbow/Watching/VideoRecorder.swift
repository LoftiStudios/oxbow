import Foundation
import OxbowKit

/// Writes one fetched video's facts and payload into the record.
///
/// **Best effort, and that is a hard requirement rather than a convenience.**
/// No write here may fail a download, fail a sweep, or mark a job failed. A
/// video that does not get its payload is a row with fewer fields, not an
/// error anybody sees (`docs/design/video-record.md` §7).
///
/// **Not a queue `Step`.** `VideoInfoFetcher`'s doc comment states the rule —
/// `info` produces no artifact, has no place in the job model, and must never
/// appear in the queue list — and the rule is right. A step that failed would
/// show a job as failed because a JPEG did not arrive, and a backfill of twenty
/// would put twenty rows in the queue for work nobody asked about.
///
/// **Synchronous, and it has to stay that way.** `videos.json` has four
/// writers, and they are safe against each other for exactly one reason: each
/// is `@MainActor` and does its load-modify-save with no suspension point in
/// between, so no other writer can interleave and have its half of the record
/// overwritten. `VideoRecordStore.load` and `.save` are both synchronous
/// precisely so that this can be. Adding an `await` between the two — or
/// wrapping this in a `Task { }` — reintroduces the interleaving this whole
/// discipline exists to prevent, silently and without a failing test.
@MainActor
enum VideoRecorder {

  static func record(
    _ fetched: VideoInfoFetcher.Fetched,
    for id: String,
    helperVersion: String?,
    records: VideoRecordStore,
    payloads: PayloadStore)
  {
    // The payload goes first: its version stamp only belongs on the record if
    // the bytes it describes actually landed. An unstamped payload cannot be
    // re-parsed later, so one is never written anonymously.
    var stamp: String?
    if let helperVersion, (try? payloads.save(fetched.payload, for: id)) != nil {
      stamp = helperVersion
    }

    guard var library = try? records.load() else { return }
    library.record(VideoRecord(
      id: id,
      login: fetched.info.login,
      title: fetched.info.title,
      durationSeconds: Int(fetched.info.duration.components.seconds),
      publishedAt: fetched.info.createdAt,
      qualities: fetched.info.qualities,
      thumbnailURLs: fetched.info.thumbnailURLs,
      payloadHelperVersion: stamp))
    try? records.save(library)
  }

  /// Records what happened to a job, keyed by the video it was downloading.
  ///
  /// `deliveredPath` takes the **first** delivered file. A composite job
  /// delivers several — video, chat, rendered chat — and the row is about the
  /// video; the rest stay reachable from the job itself. A finished job that
  /// delivered nothing records no path rather than an empty one, because the
  /// path is a claim stage 3b checks against the disk and a false claim is
  /// worse than an absent one.
  ///
  /// `failed` is deliberately a state that does **not** count as seen
  /// (`WatchState.countsAsSeen`), so a failed archive becomes actionable again.
  static func recordCompletion(
    mediaIdentifier: String,
    outcome: NotificationDecision.Outcome,
    files: [URL],
    into store: VideoRecordStore)
  {
    guard var library = try? store.load() else { return }

    switch outcome {
    case .finished:
      library.record(VideoRecord(
        id: mediaIdentifier,
        deliveredPath: files.first?.path(percentEncoded: false)))
      library.setState(.downloaded, for: mediaIdentifier)
    case .failed:
      library.record(VideoRecord(id: mediaIdentifier))
      library.setState(.failed, for: mediaIdentifier)
    }

    try? store.save(library)
  }
}

/// The two stores a submission records into, kept together because neither is
/// useful without the other.
///
/// **One value rather than two parameters** so that "this submission records"
/// and "this submission does not" is a single `nil` check at every call site,
/// instead of a pair that a future edit could leave half-supplied — a
/// `VideoRecordStore` with no `PayloadStore` beside it would quietly write
/// facts and drop every payload, which is exactly the failure that has no
/// symptom until somebody goes looking for a payload years later.
///
/// Built from `AppComposition`'s two path decisions rather than choosing paths
/// of its own, for the reason `WatchPoller.videoRecordStore` gives at length:
/// one site decides where each piece of Oxbow's state on disk lives, and a
/// second call site that picked its own path — even the identical one — could
/// drift out from under the first with nothing to notice.
struct VideoRecording {
  let records: VideoRecordStore
  let payloads: PayloadStore

  static func live(supportDirectory: URL) -> VideoRecording {
    VideoRecording(
      records: VideoRecordStore(
        fileURL: AppComposition.videoRecordURL(supportDirectory: supportDirectory)),
      payloads: PayloadStore(
        directory: AppComposition.payloadDirectory(supportDirectory: supportDirectory)))
  }
}
