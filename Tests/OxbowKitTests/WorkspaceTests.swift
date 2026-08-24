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
}
