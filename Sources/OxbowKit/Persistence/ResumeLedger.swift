import Foundation

/// Manages retained composite pieces and the next resume point (`docs/design/resume.md` §§7–8).
/// Cleanup goes through `TeardownJournal`. Synchronous and Sendable so context construction
/// needs no suspension.
struct ResumeLedger: Sendable {
  private let workspace: Workspace
  private let journal: TeardownJournal

  init(workspace: Workspace, journal: TeardownJournal) {
    self.workspace = workspace
    self.journal = journal
  }

  /// Piece limit before a retry starts over. Bounds repeated encode boundaries and retained
  /// output for persistently failing jobs; see `docs/design/resume.md` §7.
  static let maximumPieces = 4

  /// The pieces already on disk for a job, in order.
  func pieces(of job: JobID) -> [URL] {
    let directory = workspace.resumeDirectory(job)
    let contents = (try? FileManager.default.contentsOfDirectory(
      at: directory, includingPropertiesForKeys: nil)) ?? []
    return contents
      .filter { $0.lastPathComponent.hasPrefix("piece-") }
      .sorted { $0.lastPathComponent.compare(
        $1.lastPathComponent, options: .numeric) == .orderedAscending }
  }

  /// Bytes held in the retention area for a job. See
  /// `QueueEngine.retainedBytes(forJob:)` for why this is surfaced at all.
  func retainedBytes(forJob id: JobID) -> Int {
    pieces(of: id).reduce(0) { total, piece in
      total + (((try? FileManager.default
        .attributesOfItem(atPath: piece.path))?[.size] as? NSNumber)?.intValue ?? 0)
    }
  }

  /// The retention directory and the pieces in it. See
  /// `QueueEngine.retainedFileURLs(forJob:)` for why the directory is
  /// returned even when there are no pieces yet.
  func retainedFileURLs(forJob id: JobID) -> (directory: URL, pieces: [URL]) {
    (workspace.resumeDirectory(id), pieces(of: id))
  }

  /// Repairs the last piece, counts what survived, and says where to resume.
  ///
  /// Returns `nil` for a first attempt and when the piece cap is hit — in the
  /// latter case the retained pieces are dropped first, so the caller starts
  /// from `piece-0` with a clean directory.
  func resumePoint(
    job: JobID, framerate: Int)
    -> (index: Int, from: Duration?)
  {
    let existing = pieces(of: job)
    guard !existing.isEmpty else { return (0, nil) }
    guard existing.count < Self.maximumPieces else {
      journal.removeResumable(job)
      return (0, nil)
    }

    // Only the last piece can be torn — earlier ones were completed before
    // the next began. Repair is a no-op on an untorn file.
    if let last = existing.last { _ = try? FragmentedMP4.repair(last) }

    // Discard zero-frame pieces: they contain nothing usable, waste a piece slot, and would
    // create an empty concat segment.
    var survivors: [URL] = []
    var frames = 0
    for piece in existing {
      let count = (try? FragmentedMP4.index(of: piece))?.frameCount ?? 0
      if count > 0 {
        survivors.append(piece)
        frames += count
      } else {
        try? FileManager.default.removeItem(at: piece)
      }
    }
    guard frames > 0 else {
      journal.removeResumable(job)
      return (0, nil)
    }
    return (survivors.count, .seconds(Double(frames) / Double(framerate)))
  }
}
