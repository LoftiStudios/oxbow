import Foundation
import OxbowKit

/// Best-effort metadata recording must never fail a download or sweep. Keep main-actor
/// load-modify-save synchronous so multiple video-record writers cannot overwrite each other
/// across suspensions.
@MainActor
enum VideoRecorder {

  /// Write facts and queued state together. queued counts as seen, preventing duplicate offers
  /// during the next sweep.
  static func record(
    _ fetched: VideoInfoFetcher.Fetched,
    for id: String,
    helperVersion: String?,
    records: VideoRecordStore,
    payloads: PayloadStore)
  {
    // Write the versioned payload first; stamp the record only after its bytes land. Never
    // store an anonymous payload.
    var stamp: String?
    if let helperVersion, (try? payloads.save(fetched.payload, for: id)) != nil {
      stamp = helperVersion
    }

    guard var library = try? records.load() else { return }
    library.record(VideoRecord(
      id: id,
      login: fetched.info.login,
      displayName: fetched.info.streamer,
      title: fetched.info.title,
      durationSeconds: Int(fetched.info.duration.components.seconds),
      publishedAt: fetched.info.createdAt,
      qualities: fetched.info.qualities,
      thumbnailURLs: fetched.info.thumbnailURLs,
      payloadHelperVersion: stamp))
    library.setState(.queued, for: id)
    try? records.save(library)
  }

  /// Record outcome by media id, using the first delivered file when present. Failed state does
  /// not count as seen and makes the archive actionable again.
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

/// Paired record and payload stores resolved by AppComposition. One optional handle enables or
/// disables submission recording together.
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
