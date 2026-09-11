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

  /// Live from Twitch, else remembered from the record, else nothing.
  ///
  /// **Moved verbatim out of `JobInfoWindow.loadMetadata()`** — the order of
  /// these three attempts is the behaviour `video-record.md` exists to
  /// provide, and this extraction deliberately changed none of it.
  static func resolve(
    identifier: String?,
    controller: QueueController,
    record: VideoRecordStore?
  ) async -> VideoInfoLoad {
    guard let identifier else { return .unavailable }

    if let info = try? await controller.fetchInfo(for: identifier) {
      return .loaded(info)
    }

    // A private, deleted or expired VOD. Twitch has no answer any more, but
    // the metadata was fetched once while it did and written down — which is
    // the entire reason `docs/design/video-record.md` exists. Before the
    // record, this is where the card became a grey rectangle with whatever
    // title the job happened to store.
    //
    // Rendered as `.loaded`, not as a third state: a remembered card and a
    // live one describe the same video and should read identically. The one
    // visible difference is that `streamer` falls back to the login, because
    // a record holds no display name — see `VideoRecord.remembered()`.
    if let remembered = record.flatMap({ try? $0.load() })?
      .videos[identifier]?.remembered()
    {
      return .loaded(remembered)
    }

    // Nothing live and nothing remembered — a video downloaded before the
    // record existed, or one whose row migrated from the old bare-id
    // seen-set and never gained a title. The card falls back to the job's own
    // title, which is all that survives.
    return .unavailable
  }
}
