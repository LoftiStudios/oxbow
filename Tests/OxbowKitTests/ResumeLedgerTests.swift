import Foundation
import Testing

@testable import OxbowKit

/// Direct ledger tests cover file arrangements that are expensive to reach through real
/// interrupted composites.
@Suite("ResumeLedger")
struct ResumeLedgerTests {

  private func makeLedger() -> (ledger: ResumeLedger, workspace: Workspace, job: JobID) {
    let root = URL(filePath: NSTemporaryDirectory())
      .appending(path: "oxbow-ledger-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let workspace = Workspace(root: root)
    let journal = TeardownJournal(workspace: workspace)
    return (
      ResumeLedger(workspace: workspace, journal: journal),
      workspace,
      JobID(rawValue: UUID()))
  }

  private func cleanUp(_ workspace: Workspace) {
    try? FileManager.default.removeItem(at: workspace.root)
  }

  /// Writes `piece-<index>.mp4` declaring `frames` samples across one fragment.
  @discardableResult
  private func writePiece(
    _ index: Int, frames: UInt32, job: JobID, workspace: Workspace) throws -> URL
  {
    let directory = try workspace.prepareResume(job: job)
    let url = directory.appending(path: "piece-\(index).mp4")
    try FragmentBuilder.fragmentedFile(frames == 0 ? [] : [frames]).write(to: url)
    return url
  }

  // MARK: - pieces(of:)

  /// Sort piece numbers numerically; lexicographic order would concatenate piece 10 before
  /// piece 2.
  @Test func piecesSortNumericallyRatherThanLexicographically() throws {
    let (ledger, workspace, job) = makeLedger()
    defer { cleanUp(workspace) }

    for index in [0, 1, 2, 10, 11] {
      try writePiece(index, frames: 30, job: job, workspace: workspace)
    }

    let names = ledger.pieces(of: job).map(\.lastPathComponent)
    #expect(
      names == ["piece-0.mp4", "piece-1.mp4", "piece-2.mp4", "piece-10.mp4", "piece-11.mp4"],
      "pieces must sort numerically; was: \(names)")
  }

  /// Exclude fingerprint and audio sidecar from the piece list.
  @Test func piecesIgnoresEverythingThatIsNotAPiece() throws {
    let (ledger, workspace, job) = makeLedger()
    defer { cleanUp(workspace) }

    let directory = try workspace.prepareResume(job: job)
    try writePiece(0, frames: 30, job: job, workspace: workspace)
    try Data("{}".utf8).write(to: directory.appending(path: "source.json"))
    try Data("aac".utf8).write(to: directory.appending(path: "audio.m4a"))

    let names = ledger.pieces(of: job).map(\.lastPathComponent)
    #expect(names == ["piece-0.mp4"], "only pieces should be listed; was: \(names)")
  }

  @Test func piecesIsEmptyWhenTheDirectoryDoesNotExist() {
    let (ledger, workspace, job) = makeLedger()
    defer { cleanUp(workspace) }

    #expect(ledger.pieces(of: job).isEmpty)
  }

  // MARK: - retained size and URLs

  @Test func retainedBytesSumsThePiecesOnDisk() throws {
    let (ledger, workspace, job) = makeLedger()
    defer { cleanUp(workspace) }

    let a = try writePiece(0, frames: 30, job: job, workspace: workspace)
    let b = try writePiece(1, frames: 30, job: job, workspace: workspace)
    let expected = try [a, b].reduce(0) { total, url in
      total + (try Data(contentsOf: url).count)
    }

    #expect(ledger.retainedBytes(forJob: job) == expected)
  }

  @Test func retainedBytesIsZeroWithNoPieces() {
    let (ledger, workspace, job) = makeLedger()
    defer { cleanUp(workspace) }

    #expect(ledger.retainedBytes(forJob: job) == 0)
  }

  /// Return even an empty retention directory for Finder reveal before the first fragment
  /// lands.
  @Test func retainedFileURLsReportTheDirectoryEvenWithNoPieces() {
    let (ledger, workspace, job) = makeLedger()
    defer { cleanUp(workspace) }

    let (directory, pieces) = ledger.retainedFileURLs(forJob: job)
    #expect(directory == workspace.resumeDirectory(job))
    #expect(pieces.isEmpty)
  }

  // MARK: - resumePoint

  @Test func aFirstAttemptHasNoResumePoint() {
    let (ledger, workspace, job) = makeLedger()
    defer { cleanUp(workspace) }

    let resume = ledger.resumePoint(job: job, framerate: 30)
    #expect(resume.index == 0)
    #expect(resume.from == nil)
  }

  /// Two pieces of 30 frames each at 30fps is two seconds of survivors, and
  /// the next piece is index 2.
  @Test func aResumePointCountsTheSurvivingFrames() throws {
    let (ledger, workspace, job) = makeLedger()
    defer { cleanUp(workspace) }

    try writePiece(0, frames: 30, job: job, workspace: workspace)
    try writePiece(1, frames: 30, job: job, workspace: workspace)

    let resume = ledger.resumePoint(job: job, framerate: 30)
    #expect(resume.index == 2)
    #expect(resume.from == .seconds(2))
  }

  /// Use literal three/four-piece fixtures to pin the cap itself. Counts derived from
  /// `maximumPieces` would pass after an accidental cap change.
  @Test func thePieceCapIsFourAndStartingOverClearsTheArea() throws {
    let (belowLedger, belowWorkspace, belowJob) = makeLedger()
    defer { cleanUp(belowWorkspace) }
    for index in 0..<3 {
      try writePiece(index, frames: 30, job: belowJob, workspace: belowWorkspace)
    }
    let below = belowLedger.resumePoint(job: belowJob, framerate: 30)
    #expect(below.index == 3, "three pieces, one under the cap, must resume, not start over")
    #expect(below.from != nil, "one under the cap must have a resume point")

    let (atLedger, atWorkspace, atJob) = makeLedger()
    defer { cleanUp(atWorkspace) }
    for index in 0..<4 {
      try writePiece(index, frames: 30, job: atJob, workspace: atWorkspace)
    }
    let at = atLedger.resumePoint(job: atJob, framerate: 30)
    #expect(at.index == 0, "four pieces, at the cap, must start over from piece-0")
    #expect(at.from == nil, "at the cap there is no resume point")
    #expect(
      atLedger.pieces(of: atJob).isEmpty,
      "starting over must clear the retention area, or piece-0 lands beside stale pieces")

    #expect(ResumeLedger.maximumPieces == 4, "docs/design/resume.md §7 sets the cap at four")
  }

  /// Discard zero-frame pieces so they consume neither a slot nor a concat segment.
  @Test func aZeroFramePieceIsDiscardedRatherThanCounted() throws {
    let (ledger, workspace, job) = makeLedger()
    defer { cleanUp(workspace) }

    try writePiece(0, frames: 30, job: job, workspace: workspace)
    try writePiece(1, frames: 0, job: job, workspace: workspace)

    let resume = ledger.resumePoint(job: job, framerate: 30)
    #expect(resume.index == 1, "only the surviving piece counts toward the next index")
    #expect(resume.from == .seconds(1), "only surviving frames count toward the resume point")
    #expect(
      ledger.pieces(of: job).map(\.lastPathComponent) == ["piece-0.mp4"],
      "the frameless piece must be removed from disk, not merely skipped")
  }

  /// All-frameless retention must remove the directory too; checking only the piece list cannot
  /// distinguish cleanup from individual deletions.
  @Test func anAllFramelessDirectoryStartsOver() throws {
    let (ledger, workspace, job) = makeLedger()
    defer { cleanUp(workspace) }

    try writePiece(0, frames: 0, job: job, workspace: workspace)
    try writePiece(1, frames: 0, job: job, workspace: workspace)

    let resume = ledger.resumePoint(job: job, framerate: 30)
    #expect(resume.index == 0)
    #expect(resume.from == nil)
    #expect(ledger.pieces(of: job).isEmpty, "the area must be cleared")
    #expect(
      !FileManager.default.fileExists(atPath: workspace.resumeDirectory(job).path),
      "the retention directory itself must be removed, not merely emptied of pieces")
  }

  /// The same 60 frames resume at different times for 30/60 fps. Neither call mutates this
  /// valid one-piece fixture.
  @Test func theResumePointScalesWithFramerate() throws {
    let (ledger, workspace, job) = makeLedger()
    defer { cleanUp(workspace) }

    try writePiece(0, frames: 60, job: job, workspace: workspace)

    #expect(ledger.resumePoint(job: job, framerate: 30).from == .seconds(2))
    #expect(
      ledger.resumePoint(job: job, framerate: 60).from == .seconds(1),
      "the same pieces must resume earlier at a higher framerate")
  }
}
