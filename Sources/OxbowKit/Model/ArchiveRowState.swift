import Foundation

/// What one row in the Watching pane is, as a pure decision.
///
/// **The view renders this and decides nothing.** Every input is resolved by
/// the caller — the archive, the jobs the queue holds, and what the
/// filesystem answered — which is what lets every rule here be tested
/// without a window, a queue or a disk. The same shape `AutoDownloadPolicy`
/// and `WatchPollPolicy` already use for the sweep's other decisions.
public enum ArchiveRowState: Equatable, Sendable {

  /// What the filesystem said about a delivered file.
  ///
  /// **Three answers, never two.** `absent` means the volume answered and
  /// the file is not there; `unknown` means the volume could not be asked.
  /// Collapsing them is the mistake that had every NAS-backed channel
  /// demoted forever — `volumeAvailableCapacityForImportantUsage` answers
  /// *zero* on a network volume rather than nil, and every `??` fallback
  /// sailed past it (see `VolumeSpace.betterCapacity`'s doc comment). Here
  /// the same collapse would empty a library from the view the moment its
  /// drive was unplugged (`docs/design/channel-history.md` §4.1).
  public enum FileAnswer: Equatable, Sendable {
    case present(URL)
    case absent
    case unknown(volumeName: String)
  }

  /// On Twitch, nothing has happened to it. The actionable row.
  case available
  /// Still being broadcast. Not offered — `docs/design/channel-watching.md`
  /// §5.2 skips these until the broadcast ends, because what exists now is
  /// half a video.
  case live
  case queued
  case running
  /// Downloaded, and the file is where the job left it.
  case downloaded(URL)
  /// Downloaded once, and the file is not there now. §4: deleting a download
  /// un-does it, so this reads as something to fetch again rather than
  /// something you have.
  case missing
  /// Downloaded, and its volume could not be asked. Never `missing`.
  case unverifiable(volumeName: String)
  case failed

  /// Whether this row offers to fetch the archive.
  ///
  /// `missing` is included deliberately: the file is gone and Twitch still
  /// has it, which is exactly the case §4 says should return to actionable.
  public var isFetchable: Bool {
    switch self {
    case .available, .missing, .failed: true
    case .live, .queued, .running, .downloaded, .unverifiable: false
    }
  }

  /// Decides a row's state.
  ///
  /// - Parameters:
  ///   - jobs: every job the queue holds. Filtered here by
  ///     `mediaIdentifier`, so callers hand over the whole list rather than
  ///     pre-filtering it differently at each call site.
  ///   - file: asked only when a finished job actually delivered something.
  ///     A closure rather than a `VolumeSpace`, so a test answers without a
  ///     disk and this file needs no persistence import.
  public static func state(
    for archive: ChannelArchive, jobs: [Job], file: (URL) -> FileAnswer
  ) -> ArchiveRowState {
    let mine = jobs.filter { $0.mediaIdentifier == archive.id }

    // Unfinished first, and before the status check below, because a
    // re-download after a delete legitimately leaves two jobs for one
    // archive. The one still running is what the person is waiting on, and
    // which of the two comes first in `jobs` is not something to depend on.
    if let unfinished = mine.first(where: { $0.status.isUnfinished }) {
      return unfinished.status == .running ? .running : .queued
    }

    if mine.contains(where: { $0.status == .failed }) { return .failed }

    if let done = mine.first(where: { $0.status == .done }) {
      // An interrupted run can leave a finished job with nothing delivered.
      // It cannot claim a file it does not name.
      guard let delivered = done.deliveredFiles.first else { return .missing }
      switch file(delivered) {
      case .present(let url): return .downloaded(url)
      case .absent: return .missing
      case .unknown(let volume): return .unverifiable(volumeName: volume)
      }
    }

    // No job, or only cancelled ones — a cancellation is a person saying no,
    // not the app having tried and lost, so it leaves the archive offerable
    // exactly as `AutoDownloadObserver` already treats it.
    return archive.status == .recording ? .live : .available
  }
}
