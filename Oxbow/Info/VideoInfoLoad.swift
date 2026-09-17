import Foundation
import OxbowKit

/// Shared metadata-loading state for Get Info and the inspector. Distinguish loading from
/// unavailable so the card can keep its space in either case.
enum VideoInfoLoad {
  case loading
  case loaded(VideoInfo)
  case unavailable
}

extension VideoInfoLoad {

  /// Resolve a video identifier, including job-keyed targets, for metadata and record lookups.
  static func identifier(for target: InfoTarget, jobs: [Job]) -> String? {
    switch target {
    case .video(let identifier):
      return identifier
    case .job(let id):
      guard let job = jobs.first(where: { $0.id == id }) else { return nil }
      return JobInfo(job: job).sourceIdentifier
    }
  }

  /// Get Info requests fresh metadata; the inspector prefers the record to avoid subprocess and
  /// network costs on every selection change.
  enum Freshness {
    /// Ask Twitch first, then fall back to the record.
    case live
    /// Use the record first; titles may remain stale until a live fetch.
    case remembered
  }

  /// Try sources in freshness order, returning unavailable if neither succeeds.
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

    // Fall back to the job title when neither source has metadata.
    return .unavailable
  }

  /// Render remembered metadata as loaded so it uses the same card as live data.
  private static func remembered(
    _ identifier: String, in record: VideoRecordStore?
  ) -> VideoInfo? {
    record.flatMap { try? $0.load() }?.videos[identifier]?.remembered()
  }
}
