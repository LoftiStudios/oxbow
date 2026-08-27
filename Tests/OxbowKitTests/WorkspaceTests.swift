import Darwin
import Foundation
import Testing
@testable import OxbowKit

@Suite("Workspace")
struct WorkspaceTests {

  private func makeWorkspace() -> Workspace {
    Workspace(root: URL(filePath: NSTemporaryDirectory())
      .appending(path: "oxbow-ws-\(UUID().uuidString)"))
  }

  /// `removeAll()` deliberately spares `root`, so tests must take it down
  /// themselves rather than leaving an empty directory in the temp dir.
  private func tearDown(_ workspace: Workspace) {
    try? FileManager.default.removeItem(at: workspace.root)
  }

  /// A step's own directory is deleted the moment the step ends, so a log
  /// kept there would vanish exactly when someone wants to read why the step
  /// failed. Logs live at the job level, like the artifacts they explain.
  @Test func aStepLogOutlivesItsStepDirectory() throws {
    let workspace = makeWorkspace()
    defer { tearDown(workspace) }
    let job = Build.jobID(1)
    let step = Build.stepID(1)

    _ = try workspace.prepareStep(job: job, step: step)
    // `StepLog` creates the containing directory on first append; stand in
    // for that here.
    let log = workspace.logFile(job: job, step: step)
    try FileManager.default.createDirectory(
      at: log.deletingLastPathComponent(), withIntermediateDirectories: true)
    FileManager.default.createFile(atPath: log.path, contents: Data("hello".utf8))

    workspace.removeStep(job: job, step: step)

    #expect(FileManager.default.fileExists(atPath: log.path), "the log died with the step directory")
    #expect(!log.path.hasPrefix(workspace.stepDirectory(job: job, step: step).path))
    #expect(log.path.hasPrefix(workspace.jobDirectory(job).path))
  }

  @Test func removingAJobTakesItsLogsWithIt() throws {
    let workspace = makeWorkspace()
    defer { tearDown(workspace) }
    let job = Build.jobID(1)
    let log = workspace.logFile(job: job, step: Build.stepID(1))
    try FileManager.default.createDirectory(
      at: log.deletingLastPathComponent(), withIntermediateDirectories: true)
    FileManager.default.createFile(atPath: log.path, contents: Data("hello".utf8))

    workspace.removeJob(job)

    #expect(!FileManager.default.fileExists(atPath: log.path))
  }

  @Test func createsAndRemovesAStepDirectory() throws {
    let workspace = makeWorkspace()
    let job = Build.jobID(1)
    let step = Build.stepID(1)

    let directory = try workspace.prepareStep(job: job, step: step)
    #expect(FileManager.default.fileExists(atPath: directory.path))

    workspace.removeStep(job: job, step: step)
    #expect(!FileManager.default.fileExists(atPath: directory.path))

    tearDown(workspace)
  }

  /// Intermediates must outlive the step that produced them, so they live in
  /// the job workspace rather than a step directory.
  @Test func artifactsDirectoryOutlivesIndividualSteps() throws {
    let workspace = makeWorkspace()
    let job = Build.jobID(1)

    let artifacts = try workspace.prepareArtifacts(job: job)
    _ = try workspace.prepareStep(job: job, step: Build.stepID(1))
    workspace.removeStep(job: job, step: Build.stepID(1))

    #expect(FileManager.default.fileExists(atPath: artifacts.path))

    tearDown(workspace)
  }

  /// Launch sweep: nothing under `jobs/` can ever be reused — and nothing
  /// outside it belongs to us. `root` is the app's whole cache directory, so a
  /// sweep that took it wholesale would wipe every other cache the app keeps.
  @Test func removeAllClearsOnlyTheJobsSubtree() throws {
    let workspace = makeWorkspace()
    _ = try workspace.prepareStep(job: Build.jobID(1), step: Build.stepID(1))

    let neighbour = workspace.root.appending(path: "thumbnails/cover.png")
    try FileManager.default.createDirectory(
      at: neighbour.deletingLastPathComponent(), withIntermediateDirectories: true)
    FileManager.default.createFile(atPath: neighbour.path, contents: Data("x".utf8))

    workspace.removeAll()

    #expect(!FileManager.default.fileExists(atPath: workspace.jobsRoot.path))
    #expect(
      FileManager.default.fileExists(atPath: neighbour.path),
      "the sweep must not take the rest of the cache directory with it")

    tearDown(workspace)
  }

  /// The containment test that gates workspace deletion: an intermediate dies
  /// with the job, a file already moved to the user's folder does not.
  @Test func containsDistinguishesIntermediatesFromMovedFiles() throws {
    let workspace = makeWorkspace()
    let job = Build.jobID(1)

    let intermediate = workspace.artifactsDirectory(job).appending(path: "chat.json")
    #expect(workspace.contains(intermediate, ofJob: job))
    #expect(!workspace.contains(URL(filePath: "/Users/me/Movies/v.mp4"), ofJob: job))
    #expect(
      !workspace.contains(intermediate, ofJob: Build.jobID(2)),
      "another job's workspace is not this one's")
  }

  /// The launch sweep must never touch retained pieces. That is the entire
  /// point of putting them outside `jobs/` — see docs/design/resume.md §3.
  @Test func removeAllSparesTheResumeArea() throws {
    let workspace = makeWorkspace()
    defer { tearDown(workspace) }
    let job = Build.jobID(1)

    _ = try workspace.prepareStep(job: job, step: Build.stepID(1))
    let resume = try workspace.prepareResume(job: job)
    let piece = resume.appending(path: "piece-0.mp4")
    try Data([0x01]).write(to: piece)

    workspace.removeAll()

    #expect(!FileManager.default.fileExists(atPath: workspace.jobsRoot.path))
    #expect(FileManager.default.fileExists(atPath: piece.path))
  }

  @Test func removeResumableDeletesOnlyThatJob() throws {
    let workspace = makeWorkspace()
    defer { tearDown(workspace) }
    let kept = Build.jobID(1)
    let dropped = Build.jobID(2)

    for job in [kept, dropped] {
      let dir = try workspace.prepareResume(job: job)
      try Data([0x01]).write(to: dir.appending(path: "piece-0.mp4"))
    }

    workspace.removeResumable(dropped)

    #expect(FileManager.default.fileExists(atPath: workspace.resumeDirectory(kept).path))
    #expect(!FileManager.default.fileExists(atPath: workspace.resumeDirectory(dropped).path))
  }

  /// `contains` answers "is this an intermediate that dies with the job
  /// workspace". A retained piece is deliberately not one.
  @Test func containsIsFalseForARetainedPiece() {
    let workspace = makeWorkspace()
    let job = Build.jobID(1)
    let piece = workspace.resumeDirectory(job).appending(path: "piece-0.mp4")

    #expect(!workspace.contains(piece, ofJob: job))
  }

  /// Forces a genuine `FileManager.removeItem` failure via the filesystem's
  /// `uchg` (user-immutable) flag — set with `chflags`, cleared the same
  /// way. Neither an open file handle (does not stop `unlink` on APFS) nor a
  /// merely read-only file (still removable by the owner of a writable
  /// directory) forces a real failure; `uchg` does, and it is the one
  /// portable way found to do it in a test.
  private func makeUndeletable(_ url: URL) throws {
    FileManager.default.createFile(atPath: url.path, contents: Data("stuck".utf8))
    let result = chflags(url.path, UInt32(UF_IMMUTABLE))
    try #require(result == 0, "precondition: chflags must succeed to force the failure this test is after")
  }

  private func makeDeletableAgain(_ url: URL) {
    chflags(url.path, 0)
  }

  /// Reproduces the incident this whole change exists for: an 8.66 GB video
  /// that survived a job's teardown while `chat.json`, `render.mp4`, and the
  /// whole `logs/` directory were correctly removed. A single recursive
  /// `FileManager.removeItem` deletes depth-first and aborts at the first
  /// failure — this is what proves `removeJob` no longer does that, and no
  /// longer swallows the fact that it happened.
  @Test func removeJobReportsAnUndeletableFileWithoutStrandingItsSiblings() throws {
    let workspace = makeWorkspace()
    defer { tearDown(workspace) }
    let job = Build.jobID(1)

    let artifacts = try workspace.prepareArtifacts(job: job)
    let chat = artifacts.appending(path: "chat.json")
    let render = artifacts.appending(path: "render.mp4")
    let video = artifacts.appending(path: "video.mp4")
    FileManager.default.createFile(atPath: chat.path, contents: Data("chat".utf8))
    FileManager.default.createFile(atPath: render.path, contents: Data("render".utf8))
    try makeUndeletable(video)
    defer { makeDeletableAgain(video) }

    let log = workspace.logFile(job: job, step: Build.stepID(1))
    try FileManager.default.createDirectory(
      at: log.deletingLastPathComponent(), withIntermediateDirectories: true)
    FileManager.default.createFile(atPath: log.path, contents: Data("hello".utf8))

    let failed = workspace.removeJob(job)

    #expect(
      failed.map(\.standardizedFileURL.path) == [video.standardizedFileURL.path],
      "should report exactly the one file it could not remove, got \(failed)")
    #expect(!FileManager.default.fileExists(atPath: chat.path), "a removable sibling must not be stranded")
    #expect(!FileManager.default.fileExists(atPath: render.path), "a removable sibling must not be stranded")
    #expect(!FileManager.default.fileExists(atPath: log.path), "an unrelated sibling directory must not be stranded")
    #expect(FileManager.default.fileExists(atPath: video.path), "the undeletable file itself must still be there")
  }

  @Test func removeStepReportsAnUndeletableFileWithoutStrandingItsSiblings() throws {
    let workspace = makeWorkspace()
    defer { tearDown(workspace) }
    let job = Build.jobID(1)
    let step = Build.stepID(1)

    let directory = try workspace.prepareStep(job: job, step: step)
    let keep = directory.appending(path: "removable.tmp")
    let stuck = directory.appending(path: "stuck.tmp")
    FileManager.default.createFile(atPath: keep.path, contents: Data("x".utf8))
    try makeUndeletable(stuck)
    defer { makeDeletableAgain(stuck) }

    let failed = workspace.removeStep(job: job, step: step)

    #expect(failed.map(\.standardizedFileURL.path) == [stuck.standardizedFileURL.path])
    #expect(!FileManager.default.fileExists(atPath: keep.path))
    #expect(FileManager.default.fileExists(atPath: stuck.path))
  }

  @Test func removeResumableReportsAnUndeletableFileWithoutStrandingItsSiblings() throws {
    let workspace = makeWorkspace()
    defer { tearDown(workspace) }
    let job = Build.jobID(1)

    let directory = try workspace.prepareResume(job: job)
    let keep = directory.appending(path: "piece-0.mp4")
    let stuck = directory.appending(path: "piece-1.mp4")
    FileManager.default.createFile(atPath: keep.path, contents: Data("x".utf8))
    try makeUndeletable(stuck)
    defer { makeDeletableAgain(stuck) }

    let failed = workspace.removeResumable(job)

    #expect(failed.map(\.standardizedFileURL.path) == [stuck.standardizedFileURL.path])
    #expect(!FileManager.default.fileExists(atPath: keep.path))
    #expect(FileManager.default.fileExists(atPath: stuck.path))
  }

  /// A directory that was never there in the first place is not a failure —
  /// there is nothing to report a problem about.
  @Test func removingAJobThatNeverExistedReportsNoFailure() {
    let workspace = makeWorkspace()
    let job = Build.jobID(1)

    #expect(workspace.removeJob(job).isEmpty)
  }
}
