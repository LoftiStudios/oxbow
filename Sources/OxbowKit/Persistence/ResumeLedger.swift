import Foundation

/// The retained pieces of an interrupted composite, and where to resume from.
///
/// A composite that dies part-way leaves its finished output as a sealed
/// piece under `Workspace.resumeDirectory`; the next attempt writes the next
/// piece beside it and `.assemble` concatenates them. This type owns what is
/// on disk there: which pieces exist, how much they cost, and — the only
/// part that decides anything — where a resumed encode should pick up.
/// docs/design/resume.md §§7, 8.
///
/// Holds a `TeardownJournal` rather than reaching for `Workspace` directly,
/// because hitting the piece cap clears the retention area, and every
/// workspace removal goes through the journal so its failures are recorded.
///
/// A `Sendable` struct over immutable state, so it has no isolation of its
/// own and every method stays synchronous — the engine calls these from
/// `makeContext`, which is `nonisolated` and must not become `async`.
struct ResumeLedger: Sendable {
  private let workspace: Workspace
  private let journal: TeardownJournal

  init(workspace: Workspace, journal: TeardownJournal) {
    self.workspace = workspace
    self.journal = journal
  }

  /// How many times a composite may be continued before a retry starts over.
  ///
  /// Each resume adds an encode boundary, and a job that has failed this many
  /// times is reporting something that continuing will not fix. Accumulating
  /// pieces turns a persistent fault into a slowly degrading file instead of
  /// a clear failure. docs/design/resume.md §7.
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

    // A piece that contributed zero frames is one FFmpeg opened (`ftyp` +
    // `moov`) but was killed before finishing a single fragment for — there
    // is nothing in it to resume from. Left on disk it would still count as
    // a real attempt: it burns a slot against `maximumPieces`, and
    // `.assemble`'s `pieces.txt` would list it as an empty segment in the
    // concat. Discarded outright rather than repaired — repair only fixes a
    // torn trailing fragment, and an absent one is not that.
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
