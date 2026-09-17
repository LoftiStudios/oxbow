import Foundation

/// Pure archive state resolution from metadata, queue jobs, and supplied filesystem answers.
public enum ArchiveRowState: Equatable, Sendable {

  /// Distinguish absent files from unreachable volumes. Unknown must not make an offline
  /// library appear deleted.
  public enum FileAnswer: Equatable, Sendable {
    case present(URL)
    case absent
    case unknown(volumeName: String)
  }

  /// On Twitch, nothing has happened to it. The actionable row.
  case available
  /// Recording or unknown status: unavailable for unattended download but offered for manual
  /// choice. The UI labels both Live; ChannelArchive.isDownloadable defines the boundary.
  case live
  case queued
  case running
  /// Downloaded, and the file is where the job left it.
  case downloaded(URL)
  /// Previously downloaded file is now absent; the archive is actionable again.
  case missing
  /// Downloaded, and its volume could not be asked. Never `missing`.
  case unverifiable(volumeName: String)
  case failed

  /// No longer listed by Twitch and no file remains. Show as history, without Add or Open
  /// actions.
  case expired

  /// Only a verified present file can open. Unlike holdsAFile, this excludes an unreachable
  /// volume.
  public var openableFile: URL? {
    if case .downloaded(let url) = self { return url }
    return nil
  }

  /// Preserve known downloads in history even when their volume is unreachable; unknown is not
  /// evidence of deletion.
  public var holdsAFile: Bool {
    switch self {
    case .downloaded, .unverifiable: true
    case .available, .live, .queued, .running, .missing, .failed, .expired: false
    }
  }

  /// Manual fetching permits missing files and live/unknown broadcasts. Unattended policy is
  /// stricter. Queued, running, downloaded, unverifiable, and expired rows are not fetchable.
  public var isFetchable: Bool {
    switch self {
    case .available, .live, .missing, .failed: true
    // Nothing to fetch: Twitch has dropped it and no file remains.
    case .expired: false
    case .queued, .running, .downloaded, .unverifiable: false
    }
  }

  /// Resolve state from all jobs, filtered here by mediaIdentifier, and injected file checks
  /// for delivered, recorded, or expected paths.
  public static func state(
    for archive: ChannelArchive,
    jobs: [Job],
    recordedPath: String?,
    expectedPath: String?,
    file: (URL) -> FileAnswer
  ) -> ArchiveRowState {
    let mine = jobs.filter { $0.mediaIdentifier == archive.id }

    // Prefer unfinished retries over older jobs for the same archive.
    if let unfinished = mine.first(where: { $0.status.isUnfinished }) {
      return unfinished.status == .running ? .running : .queued
    }

    // A successful retry outranks stale failures; verify its delivered file before claiming
    // downloaded.
    if let done = mine.first(where: { $0.status == .done }) {
      // A done job without a delivered path cannot claim a file.
      guard let delivered = done.deliveredFiles.first else { return .missing }
      switch file(delivered) {
      case .present(let url): return .downloaded(url)
      case .absent: return .missing
      case .unknown(let volume): return .unverifiable(volumeName: volume)
      }
    }

    // Recorded delivery survives queue removal. Absent recorded files fall through so a later
    // failed retry remains visible; present and unreachable claims retain their state.
    if let recordedPath {
      switch file(URL(filePath: recordedPath)) {
      case .present(let url): return .downloaded(url)
      case .unknown(let volume): return .unverifiable(volumeName: volume)
      case .absent: break
      }
    }

    // Expected paths recognize pre-record downloads only when the file is present. Unlike
    // recorded delivery, a guessed path provides no evidence when its volume is unreachable.
    // Moved or renamed files simply stop matching.
    if let expectedPath, case .present(let url) = file(URL(filePath: expectedPath)) {
      return .downloaded(url)
    }

    // Checked after the .done and expected-path cases above, deliberately: a stale
    // failure left in the queue must never outrank a file that is actually on disk.
    if mine.contains(where: { $0.status == .failed }) { return .failed }

    // Without a stronger result, use isDownloadable to distinguish available from live/unknown
    // status. Cancellation alone does not imply download failure.
    return archive.isDownloadable ? .available : .live
  }
}

extension ArchiveRowState.FileAnswer {

  /// Probe the file and its immediate parent separately. Missing file with present parent is
  /// absent; missing parent is unknown. Do not walk to the nearest existing ancestor: an
  /// unmounted /Volumes/Drive path would resolve to the boot volume.
  public static func resolve(
    _ url: URL, fileExists: (URL) -> Bool, folderExists: (URL) -> Bool
  ) -> ArchiveRowState.FileAnswer {
    if fileExists(url) { return .present(url) }
    let folder = url.deletingLastPathComponent()
    if folderExists(folder) { return .absent }
    return .unknown(volumeName: volumeName(guessedFrom: url))
  }

  /// Infer volume name from /Volumes/<name>; elsewhere use the missing folder's name.
  private static func volumeName(guessedFrom url: URL) -> String {
    let components = url.standardizedFileURL.pathComponents
    if components.count > 2, components[1] == "Volumes" {
      return components[2]
    }
    return url.deletingLastPathComponent().lastPathComponent
  }
}
