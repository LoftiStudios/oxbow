import Foundation
import Testing
@testable import OxbowKit

@Suite("Workspace")
struct WorkspaceTests {

  private func makeWorkspace() -> Workspace {
    Workspace(root: URL(filePath: NSTemporaryDirectory())
      .appending(path: "oxbow-ws-\(UUID().uuidString)"))
  }

  @Test func createsAndRemovesAStepDirectory() throws {
    let workspace = makeWorkspace()
    let job = Build.jobID(1)
    let step = Build.stepID(1)

    let directory = try workspace.prepareStep(job: job, step: step)
    #expect(FileManager.default.fileExists(atPath: directory.path))

    workspace.removeStep(job: job, step: step)
    #expect(!FileManager.default.fileExists(atPath: directory.path))

    workspace.removeAll()
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

    workspace.removeAll()
  }

  /// Launch sweep: nothing in the workspace can ever be reused.
  @Test func removeAllClearsTheEntireRoot() throws {
    let workspace = makeWorkspace()
    _ = try workspace.prepareStep(job: Build.jobID(1), step: Build.stepID(1))

    workspace.removeAll()
    #expect(!FileManager.default.fileExists(atPath: workspace.root.path))
  }
}
