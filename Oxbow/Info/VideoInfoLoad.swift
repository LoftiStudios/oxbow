import Foundation
import OxbowKit

/// Where a video's metadata came from, and how far it got.
///
/// **Extracted from `JobInfoWindow` so the inspector can share it.**
/// `docs/design/inspector.md` §4: the card is the one element that must not
/// fork, and a card is only as shared as the thing that feeds it — two
/// surfaces resolving metadata by two routes would diverge the moment one of
/// them gained a fallback the other did not.
///
/// Three states rather than an optional, so the card can tell "still coming"
/// from "never arriving" and stay the same size in both.
enum VideoInfoLoad {
  case loading
  case loaded(VideoInfo)
  case unavailable
}

extension VideoInfoLoad {

  /// Which video a target is about, for the fetch and the record lookup
  /// behind it.
  ///
  /// Shared for the same reason `resolve` is: a job-keyed target has to go
  /// through `JobInfo.sourceIdentifier` to find its video, and two copies of
  /// that hop is two places for it to stop agreeing.
  static func identifier(for target: InfoTarget, jobs: [Job]) -> String? {
    switch target {
    case .video(let identifier):
      return identifier
    case .job(let id):
      guard let job = jobs.first(where: { $0.id == id }) else { return nil }
      return JobInfo(job: job).sourceIdentifier
    }
  }

  /// Which source to try first.
  ///
  /// **The two surfaces want opposite orders, and the reason is what the whole
  /// inspector design rests on.** Get Info is a deliberate gesture on one
  /// video, where the freshest possible answer is worth a wait. The inspector
  /// is *ambient* and follows the selection, so the same wait is paid on every
  /// arrow-key press down a list.
  ///
  /// That wait is not small: `QueueController.fetchInfo` runs the CLI's `info`
  /// verb as a **child process** — .NET startup, a GraphQL call and an m3u8
  /// fetch — for metadata the record usually already holds on disk. Measured
  /// at a second or two on a phone tether, where it also spends bandwidth
  /// somebody is paying for.
  ///
  /// `video-record.md` §6.1 already draws this line: the live upgrade belongs
  /// "in one place only", which is Get Info.
  enum Freshness {
    /// Ask Twitch, fall back to the record. Get Info's order, unchanged.
    case live
    /// Use the record when there is one, and ask Twitch only when there is
    /// not. Instant, offline, and free — at the cost of a retitled VOD
    /// reading by its old name until something fetches it live.
    case remembered
  }

  /// Live from Twitch, else remembered from the record, else nothing — or the
  /// first two swapped, per `freshness`.
  ///
  /// The live-first order moved verbatim out of `JobInfoWindow.loadMetadata()`
  /// and is what `.live` still does. `.live` is the default so the window's
  /// call site did not change and cannot change by omission.
  static func resolve(
    identifier: String?,
    controller: QueueController,
    record: VideoRecordStore?,
    freshness: Freshness = .live
  ) async -> VideoInfoLoad {
    guard let identifier else { return .unavailable }

    if freshness == .remembered, let known = remembered(identifier, in: record) {
      return .loaded(known)
    }

    if let info = try? await controller.fetchInfo(for: identifier) {
      return .loaded(info)
    }

    if let known = remembered(identifier, in: record) {
      return .loaded(known)
    }

    // Nothing live and nothing remembered — a video downloaded before the
    // record existed, or one whose row migrated from the old bare-id
    // seen-set and never gained a title. The card falls back to the job's own
    // title, which is all that survives.
    return .unavailable
  }

  /// What the record kept, if anything.
  ///
  /// A private, deleted or expired VOD reaches this having had no live answer.
  /// The metadata was fetched once while Twitch still had it and written down,
  /// which is the entire reason `docs/design/video-record.md` exists — before
  /// the record, that card was a grey rectangle with whatever title the job
  /// happened to store.
  ///
  /// Rendered as `.loaded`, not as a third state: a remembered card and a live
  /// one describe the same video and should read identically. The one visible
  /// difference is that `streamer` falls back to the login, because a record
  /// holds no display name — see `VideoRecord.remembered()`.
  private static func remembered(
    _ identifier: String, in record: VideoRecordStore?
  ) -> VideoInfo? {
    record.flatMap { try? $0.load() }?.videos[identifier]?.remembered()
  }
}
