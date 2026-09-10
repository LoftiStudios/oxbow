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
  /// Not something the unattended path may take: still being broadcast, or
  /// carrying a status Twitch has introduced that this app has never seen.
  /// `ChannelArchive.isDownloadable` is what decides, so the pane and
  /// `AutoDownloadPolicy` cannot disagree about the same archive.
  ///
  /// Not urged, because what exists now may be half a video
  /// (`docs/design/channel-watching.md` §5.2) — but still offered under
  /// right-click, because that same section says a live broadcast is shown
  /// "for a human to choose". The badge calls this Live, which is what it
  /// nearly always is; an unrecognised status borrowing that word is the
  /// accepted cost of never having a second definition of "may this be
  /// taken" to keep in step with the first.
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

  /// Whether this row has something on disk to show for itself.
  ///
  /// **The question a row asks when Twitch has stopped listing its archive.**
  /// A record kept for a video that has since expired is worth rendering only
  /// while the download it produced still exists; once the file is gone too,
  /// the row is a headstone, and `docs/design/video-record.md` §5.2 keeps
  /// those behind a filter rather than in the default view.
  ///
  /// `unverifiable` counts. The volume being unplugged is not evidence the
  /// file was deleted — collapsing "could not ask" into "no" is the mistake
  /// §4.1 exists to prevent, and here it would make an entire library vanish
  /// from the view every time a disk was unmounted.
  public var holdsAFile: Bool {
    switch self {
    case .downloaded, .unverifiable: true
    case .available, .live, .queued, .running, .missing, .failed: false
    }
  }

  /// Whether a person may still choose to fetch this archive.
  ///
  /// `missing` is included deliberately: the file is gone and Twitch still
  /// has it, which is exactly the case §4 says should return to actionable.
  ///
  /// `live` is included for the reason `Watch.findings(in:)` gives for not
  /// filtering on `isDownloadable` — only the *unattended* path refuses a
  /// live broadcast (`docs/design/channel-watching.md` §5.2); a person who
  /// knowingly wants the partial may have it, and a person who does not want
  /// it at all must still be able to say so. This is the question asked on
  /// behalf of a human, and `ChannelArchive.isDownloadable` is the one asked
  /// on behalf of the machine — different audiences, deliberately different
  /// answers, and nothing derives either from the other.
  ///
  /// The states left out are the ones where fetching is not a choice anyone
  /// has: it is already happening, already done, or unanswerable until a
  /// volume comes back.
  public var isFetchable: Bool {
    switch self {
    case .available, .live, .missing, .failed: true
    case .queued, .running, .downloaded, .unverifiable: false
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
    for archive: ChannelArchive,
    jobs: [Job],
    recordedPath: String?,
    file: (URL) -> FileAnswer
  ) -> ArchiveRowState {
    let mine = jobs.filter { $0.mediaIdentifier == archive.id }

    // Unfinished first, and before the status check below, because a
    // re-download after a delete legitimately leaves two jobs for one
    // archive. The one still running is what the person is waiting on, and
    // which of the two comes first in `jobs` is not something to depend on.
    if let unfinished = mine.first(where: { $0.status.isUnfinished }) {
      return unfinished.status == .running ? .running : .queued
    }

    // Done before failed, and deliberately not source order. §6.3 of
    // channel-watching.md leaves a failed automatic download's job sitting in
    // the queue on purpose, and a retry submits a *new* job with the same
    // `mediaIdentifier` rather than replacing it — so a success can coexist
    // with a stale failure for the same archive. channel-history.md §4 makes
    // the filesystem authoritative: if the file is there, the archive is
    // downloaded, full stop, regardless of what else is in the queue for it.
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

    // The queue has forgotten this archive, but the record has not.
    //
    // **This is what stops a row's history being a lease on the queue's
    // cleanup.** Every branch above reads a `Job`, and a person removing a
    // finished download — an entirely ordinary thing to do to a queue — used
    // to erase the only evidence the archive had ever been fetched.
    // `docs/design/video-record.md` §7 records `deliveredPath` when the job
    // settles, precisely so the answer outlives the job.
    //
    // The job still wins when there is one: it names the file this run
    // actually produced, where the record names the file some earlier run
    // did.
    //
    // **`absent` falls through rather than answering `.missing`.** A recorded
    // path that is no longer on disk means the file was deleted, and §4 says
    // that returns the archive to actionable — so the remaining checks get to
    // run. That ordering matters when a retry failed after a delete: without
    // it, a stale recorded path would answer `.missing` and hide the failure
    // that is the more useful thing to say.
    if let recordedPath {
      switch file(URL(filePath: recordedPath)) {
      case .present(let url): return .downloaded(url)
      case .unknown(let volume): return .unverifiable(volumeName: volume)
      case .absent: break
      }
    }

    // A failed job with no coexisting success. Checked after `.done` so a
    // stale failure left in the queue by §6.3 never outranks a file that is
    // actually on disk.
    if mine.contains(where: { $0.status == .failed }) { return .failed }

    // No job, or only cancelled ones — a cancellation is a person saying no,
    // not the app having tried and lost, so it leaves the archive offerable
    // exactly as `AutoDownloadObserver` already treats it.
    //
    // Through `isDownloadable` rather than `status == .recording`, which is
    // the same predicate spelled out a second time and would drift the first
    // time Twitch introduces a status: an unrecognised one decodes to
    // `.other`, which `isDownloadable` refuses to call safe, and spelling it
    // out here would have read it as `.available` and offered a prominent Add
    // for an archive `AutoDownloadPolicy` declines to touch. Two surfaces
    // disagreeing about one archive is what §6.4 of
    // `docs/design/channel-watching.md` argues against.
    return archive.isDownloadable ? .available : .live
  }
}

extension ArchiveRowState.FileAnswer {

  /// Answers whether a delivered file is present, without mistaking an
  /// unreachable volume for a deleted one.
  ///
  /// **Why not `VolumeSpace.live.volumeName(_:)` / `.volumeRoot(_:)`.** Both
  /// resolve through `VolumeSpace.nearestExisting`, which walks *up* the
  /// path to the deepest ancestor that exists. That is exactly right for
  /// asking about *capacity* — every ancestor sits on the same volume, so
  /// any of them can answer how much free space it has. It is exactly wrong
  /// for asking whether *this path's* volume is present: for an unmounted
  /// `/Volumes/Helios/f.mp4`, walking up lands on `/Volumes` itself, which
  /// always exists — it is a directory on the boot volume, not on Helios.
  /// So both accessors answer non-nil for a path whose actual volume is
  /// gone, and an unplugged drive would read as a deleted file: the one
  /// case `FileAnswer` exists to keep separate from a real deletion.
  ///
  /// The honest proxy for "could this question even be asked" is the
  /// file's own parent folder, not some ancestor further up. If the folder
  /// is there and the file is not, the file is genuinely gone. If the
  /// folder is not there either, something larger than one file is
  /// missing — a whole volume, most likely — and this must not guess which
  /// file that costs.
  ///
  /// - Parameters:
  ///   - fileExists: probes the file itself.
  ///   - folderExists: probes the file's parent folder. Kept separate from
  ///     `fileExists` (rather than reusing it on the parent internally) so
  ///     a test can answer each question independently without a disk.
  public static func resolve(
    _ url: URL, fileExists: (URL) -> Bool, folderExists: (URL) -> Bool
  ) -> ArchiveRowState.FileAnswer {
    if fileExists(url) { return .present(url) }
    let folder = url.deletingLastPathComponent()
    if folderExists(folder) { return .absent }
    return .unknown(volumeName: volumeName(guessedFrom: url))
  }

  /// The volume name to report when the folder itself could not be found.
  ///
  /// Taken from the path, not from `VolumeSpace.volumeName` — see
  /// `resolve` above for why that resolver has already lost the answer by
  /// the time it would be asked. Under `/Volumes`, the component right
  /// after it is the disk's own name, the same name Finder shows (mounting
  /// `Helios` produces `/Volumes/Helios`). Outside `/Volumes` — an
  /// unreachable path that was never an external volume in the first place
  /// — the closest thing to a name is the missing folder itself.
  private static func volumeName(guessedFrom url: URL) -> String {
    let components = url.standardizedFileURL.pathComponents
    if components.count > 2, components[1] == "Volumes" {
      return components[2]
    }
    return url.deletingLastPathComponent().lastPathComponent
  }
}
