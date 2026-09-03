import Foundation
import Testing

@testable import OxbowKit

/// Direct tests for the retained-pieces logic.
///
/// `resumePoint` is reachable through the engine only by driving a real
/// composite to failure and retrying it, which is what `ResumeEndToEndTests`
/// does once, slowly. Its branches — the piece cap, a zero-frame piece, an
/// all-frameless directory — each need their own arrangement of files on
/// disk, so they are exercised here against a `ResumeLedger` directly.
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

  /// `piece-10` must sort after `piece-2`, not before it. A lexicographic
  /// sort would order the concat list wrongly and `.assemble` would splice
  /// the delivery out of order — silently, since every piece is a valid file.
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

  /// The retention directory also holds `source.json` and `audio.m4a`.
  /// Neither is a piece, and either reaching the concat list would corrupt
  /// the delivery.
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

  /// The directory is returned even when empty — it is the fallback Finder
  /// selection in the gap between a composite starting and its first
  /// fragment landing. docs/design/fragmented-output.md §6.
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

  /// **This is the test that pins `maximumPieces`.**
  ///
  /// Three pieces resume; four start over. Asserting both sides is what makes
  /// the constant load-bearing — a test that only checked the four-piece case
  /// would still pass if the cap moved to 5, because four pieces would then
  /// simply resume and the assertion would never notice which branch ran.
  /// Spec §10: mutate the constants, not only the call sites.
  @Test func thePieceCapIsFourAndStartingOverClearsTheArea() throws {
    let (belowLedger, belowWorkspace, belowJob) = makeLedger()
    defer { cleanUp(belowWorkspace) }
    for index in 0..<(ResumeLedger.maximumPieces - 1) {
      try writePiece(index, frames: 30, job: belowJob, workspace: belowWorkspace)
    }
    let below = belowLedger.resumePoint(job: belowJob, framerate: 30)
    #expect(
      below.index == ResumeLedger.maximumPieces - 1,
      "one under the cap must resume, not start over")
    #expect(below.from != nil, "one under the cap must have a resume point")

    let (atLedger, atWorkspace, atJob) = makeLedger()
    defer { cleanUp(atWorkspace) }
    for index in 0..<ResumeLedger.maximumPieces {
      try writePiece(index, frames: 30, job: atJob, workspace: atWorkspace)
    }
    let at = atLedger.resumePoint(job: atJob, framerate: 30)
    #expect(at.index == 0, "at the cap the next attempt starts from piece-0")
    #expect(at.from == nil, "at the cap there is no resume point")
    #expect(
      atLedger.pieces(of: atJob).isEmpty,
      "starting over must clear the retention area, or piece-0 lands beside stale pieces")

    #expect(ResumeLedger.maximumPieces == 4, "docs/design/resume.md §7 sets the cap at four")
  }

  /// A piece FFmpeg opened but was killed before completing a fragment for
  /// declares zero samples. Left in place it burns a slot against the cap and
  /// `.assemble` would list it as an empty segment in the concat.
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

  /// Every piece frameless means there is nothing to continue from, so the
  /// area is cleared and the next attempt is a first attempt.
  @Test func anAllFramelessDirectoryStartsOver() throws {
    let (ledger, workspace, job) = makeLedger()
    defer { cleanUp(workspace) }

    try writePiece(0, frames: 0, job: job, workspace: workspace)
    try writePiece(1, frames: 0, job: job, workspace: workspace)

    let resume = ledger.resumePoint(job: job, framerate: 30)
    #expect(resume.index == 0)
    #expect(resume.from == nil)
    #expect(ledger.pieces(of: job).isEmpty, "the area must be cleared")
  }

  /// The resume point is frames divided by the *render's* framerate, so the
  /// same pieces resume at a different timestamp at 60fps than at 30.
  @Test func theResumePointScalesWithFramerate() throws {
    let (ledger, workspace, job) = makeLedger()
    defer { cleanUp(workspace) }

    try writePiece(0, frames: 60, job: job, workspace: workspace)

    #expect(ledger.resumePoint(job: job, framerate: 30).from == .seconds(2))
  }
}
