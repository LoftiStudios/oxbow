import Darwin
import Foundation
import Testing

@testable import OxbowKit

/// Direct journal fixtures exercise large-log compaction and create/append failures without
/// driving the engine.
@Suite("TeardownJournal")
struct TeardownJournalTests {

  private func makeWorkspace() -> Workspace {
    let root = URL(filePath: NSTemporaryDirectory())
      .appending(path: "oxbow-journal-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return Workspace(root: root)
  }

  private func cleanUp(_ workspace: Workspace) {
    try? FileManager.default.removeItem(at: workspace.root)
  }

  private func contents(of workspace: Workspace) -> String {
    (try? String(contentsOf: workspace.teardownFailureLog, encoding: .utf8)) ?? ""
  }

  /// The file does not exist yet, so `record` must create it — and its parent
  /// directory with it.
  @Test func recordCreatesTheLogWhenItIsAbsent() throws {
    let workspace = makeWorkspace()
    defer { cleanUp(workspace) }
    let journal = TeardownJournal(workspace: workspace)

    #expect(!FileManager.default.fileExists(atPath: workspace.teardownFailureLog.path))

    journal.record([URL(filePath: "/tmp/stuck.mp4")], context: "first failure")

    let text = contents(of: workspace)
    #expect(text.contains("stuck.mp4"), "log should name the file; was: \(text)")
    #expect(text.contains("first failure"), "log should carry the context; was: \(text)")
  }

  /// Appending must not truncate earlier entries through `createFile`.
  @Test func recordAppendsRatherThanTruncating() throws {
    let workspace = makeWorkspace()
    defer { cleanUp(workspace) }
    let journal = TeardownJournal(workspace: workspace)

    journal.record([URL(filePath: "/tmp/first.mp4")], context: "one")
    journal.record([URL(filePath: "/tmp/second.mp4")], context: "two")

    let text = contents(of: workspace)
    #expect(text.contains("first.mp4"), "the earlier entry must survive; was: \(text)")
    #expect(text.contains("second.mp4"), "the later entry must be there; was: \(text)")
    #expect(
      text.split(separator: "\n").count == 2,
      "exactly two entries expected; was: \(text)")
  }

  /// An empty list is not a failure and must write nothing at all — otherwise
  /// every successful teardown would leave a blank line in the log.
  @Test func recordWritesNothingWhenNothingSurvived() throws {
    let workspace = makeWorkspace()
    defer { cleanUp(workspace) }
    let journal = TeardownJournal(workspace: workspace)

    journal.record([], context: "clean teardown")

    #expect(
      !FileManager.default.fileExists(atPath: workspace.teardownFailureLog.path),
      "an empty failure list must not create the log at all")
  }

  /// Seed above the hysteresis threshold directly to test compaction without thousands of
  /// writes.
  @Test func anOversizedLogIsCompacted() throws {
    let workspace = makeWorkspace()
    defer { cleanUp(workspace) }
    let journal = TeardownJournal(workspace: workspace)

    let cap = StepLog.defaultMaxBytes
    // One 64-byte line repeated past cap + cap/2 (= 393216 bytes).
    let line = String(repeating: "x", count: 63) + "\n"
    let seeded = String(repeating: line, count: (cap + cap / 2) / 64 + 200)
    try Data(seeded.utf8).write(to: workspace.teardownFailureLog)
    #expect(
      try Data(contentsOf: workspace.teardownFailureLog).count > cap + cap / 2,
      "precondition: the seeded log must exceed the compaction threshold")

    journal.record([URL(filePath: "/tmp/trigger.mp4")], context: "triggers compaction")

    let after = try Data(contentsOf: workspace.teardownFailureLog).count
    #expect(after <= cap, "compaction should bring the log back to at most \(cap); was \(after)")
  }

  /// Compaction must preserve whole lines.
  @Test func compactionCutsOnLineBoundaries() throws {
    let workspace = makeWorkspace()
    defer { cleanUp(workspace) }
    let journal = TeardownJournal(workspace: workspace)

    let cap = StepLog.defaultMaxBytes
    let line = String(repeating: "y", count: 63) + "\n"
    let seeded = String(repeating: line, count: (cap + cap / 2) / 64 + 200)
    try Data(seeded.utf8).write(to: workspace.teardownFailureLog)

    journal.record([URL(filePath: "/tmp/trigger.mp4")], context: "triggers compaction")

    let text = contents(of: workspace)
    // Identical lines make content checks insufficient; also require the compacted size to
    // prove trimming occurred.
    #expect(
      text.utf8.count <= cap,
      "compaction should have fired and brought the log back to at most \(cap); was \(text.utf8.count)"
    )
    let first = try #require(text.split(separator: "\n").first)
    #expect(
      first.count == 63 || first.contains("trigger.mp4"),
      "the first surviving line must be whole, not a partial cut; was: \(first)")
  }

  /// Seed at cap + cap/4, between cap and the compaction threshold, to prove hysteresis delays
  /// rewriting.
  @Test func aLogUnderTheThresholdIsLeftAlone() throws {
    let workspace = makeWorkspace()
    defer { cleanUp(workspace) }
    let journal = TeardownJournal(workspace: workspace)

    let cap = StepLog.defaultMaxBytes
    let line = String(repeating: "z", count: 63) + "\n"
    let seeded = String(repeating: line, count: (cap + cap / 4) / 64)
    try Data(seeded.utf8).write(to: workspace.teardownFailureLog)
    let before = try Data(contentsOf: workspace.teardownFailureLog).count
    #expect(before > cap, "precondition: the seeded log must already exceed cap")
    #expect(
      before <= cap + cap / 2,
      "precondition: the seeded log must stay under the compaction threshold")

    journal.record([URL(filePath: "/tmp/small.mp4")], context: "well under the threshold")

    let text = contents(of: workspace)
    #expect(text.hasPrefix(seeded), "the existing content must be untouched")
    #expect(text.contains("small.mp4"), "the new entry must be appended")
    let after = try Data(contentsOf: workspace.teardownFailureLog).count
    #expect(
      after > cap,
      "compaction must not have fired: the file should still be larger than cap; was \(after)")
  }

  /// Use user-immutable flags to force real deletion failure without root.
  @Test func removeStepReportsAFileItCouldNotRemove() async throws {
    let workspace = makeWorkspace()
    defer { cleanUp(workspace) }
    let journal = TeardownJournal(workspace: workspace)
    let job = JobID(rawValue: UUID())
    let step = StepID(rawValue: UUID())

    let directory = try workspace.prepareStep(job: job, step: step)
    let stuck = directory.appending(path: "stuck.tmp")
    FileManager.default.createFile(atPath: stuck.path, contents: Data("x".utf8))
    try #require(
      chflags(stuck.path, UInt32(UF_IMMUTABLE)) == 0,
      "precondition: chflags must succeed to force the failure this test is after")
    defer { chflags(stuck.path, 0) }

    journal.removeStep(job: job, step: step)

    // recordStepTeardownFailure writes through a fire-and-forget Task, so the
    // line may still be in flight — poll rather than reading exactly once.
    let logFile = workspace.logFile(job: job, step: step)
    var text = ""
    for _ in 0..<80 {
      text = (try? String(contentsOf: logFile, encoding: .utf8)) ?? ""
      if text.contains("stuck.tmp") { break }
      try await Task.sleep(for: .milliseconds(25))
    }

    #expect(text.contains("teardown"), "the step log should record it; was: \(text)")
    #expect(text.contains("stuck.tmp"), "it should name the file; was: \(text)")
    #expect(FileManager.default.fileExists(atPath: stuck.path), "the file must still be there")
  }

  /// `removeResumable` reports into the workspace-level log, not a step's,
  /// because the retention area belongs to no single step.
  @Test func removeResumableReportsIntoTheWorkspaceLog() throws {
    let workspace = makeWorkspace()
    defer { cleanUp(workspace) }
    let journal = TeardownJournal(workspace: workspace)
    let job = JobID(rawValue: UUID())

    let directory = try workspace.prepareResume(job: job)
    let stuck = directory.appending(path: "piece-0.mp4")
    FileManager.default.createFile(atPath: stuck.path, contents: Data("x".utf8))
    try #require(
      chflags(stuck.path, UInt32(UF_IMMUTABLE)) == 0,
      "precondition: chflags must succeed to force the failure this test is after")
    defer { chflags(stuck.path, 0) }

    journal.removeResumable(job)

    let text = contents(of: workspace)
    #expect(text.contains(job.rawValue.uuidString), "should name the job; was: \(text)")
    #expect(text.contains("resumable area"), "should name the area; was: \(text)")
    #expect(text.contains("piece-0.mp4"), "should name the file; was: \(text)")
  }

  /// A teardown with nothing left behind writes no log at all.
  @Test func aCleanTeardownRecordsNothing() throws {
    let workspace = makeWorkspace()
    defer { cleanUp(workspace) }
    let journal = TeardownJournal(workspace: workspace)
    let job = JobID(rawValue: UUID())

    _ = try workspace.prepareResume(job: job)
    journal.removeResumable(job)

    #expect(
      !FileManager.default.fileExists(atPath: workspace.teardownFailureLog.path),
      "a teardown that succeeded must leave no failure record")
  }

  // MARK: - Spent inputs

  /// Pre-assembly fixture with spent media/render and retained transcript/piece, all within the
  /// workspace.
  private func assembleReadyJob(
    _ workspace: Workspace,
    videoArtifact: URL? = nil,
    chatArtifact: URL? = nil,
    renderArtifact: URL? = nil,
    compositeArtifact: URL? = nil) -> Job
  {
    Job(
      id: Build.jobID(1),
      created: Date(timeIntervalSince1970: 0),
      title: "spent inputs",
      steps: [
        Step(
          id: Build.stepID(1),
          kind: .downloadVideo(VideoRequest(videoID: "v", quality: "best")),
          status: .done,
          artifact: videoArtifact),
        Step(
          id: Build.stepID(2),
          kind: .downloadChat(ChatRequest(videoID: "v", format: .json)),
          status: .done,
          artifact: chatArtifact),
        Step(
          id: Build.stepID(3),
          kind: .renderChat(RenderRequest()),
          status: .done,
          artifact: renderArtifact),
        Step(
          id: Build.stepID(4),
          kind: .composite(CompositeRequest(
            framerate: 30, duration: .seconds(60),
            destination: workspace.root.appending(path: "out.mp4"))),
          status: .done,
          artifact: compositeArtifact),
      ])
  }

  /// Writes a real file at `name` inside the job's artifacts directory and
  /// returns where it landed.
  @discardableResult
  private func writeArtifact(_ name: String, of job: JobID, in workspace: Workspace) throws -> URL {
    let url = try workspace.prepareArtifacts(job: job).appending(path: name)
    try Data("x".utf8).write(to: url)
    return url
  }

  /// Remove media/render before assembly to limit recovery peak disk use.
  @Test func spentInputsDropsTheVideoAndTheChatRender() throws {
    let workspace = makeWorkspace()
    defer { cleanUp(workspace) }
    let journal = TeardownJournal(workspace: workspace)
    let id = Build.jobID(1)
    let video = try writeArtifact("video.mp4", of: id, in: workspace)
    let render = try writeArtifact("render.mp4", of: id, in: workspace)

    journal.removeSpentInputs(of: assembleReadyJob(
      workspace, videoArtifact: video, renderArtifact: render))

    #expect(!FileManager.default.fileExists(atPath: video.path),
            "the re-fetched video must be gone — resume.md §5")
    #expect(!FileManager.default.fileExists(atPath: render.path),
            "the re-fetched chat render must be gone — resume.md §5")
  }

  /// Use a separate clip fixture because a real job does not contain both video and clip
  /// sources.
  @Test func spentInputsDropsAClipTheSameWayItDropsAVideo() throws {
    let workspace = makeWorkspace()
    defer { cleanUp(workspace) }
    let journal = TeardownJournal(workspace: workspace)
    let id = Build.jobID(1)
    let clip = try writeArtifact("clip.mp4", of: id, in: workspace)

    var job = assembleReadyJob(workspace)
    job.steps[0] = Step(
      id: Build.stepID(1),
      kind: .downloadClip(ClipRequest(clipSlug: "c", quality: "best")),
      status: .done,
      artifact: clip)
    journal.removeSpentInputs(of: job)

    #expect(!FileManager.default.fileExists(atPath: clip.path))
  }

  /// Preserve transcript and pieces. Assert video deletion as a positive control against no-op
  /// cleanup.
  @Test func spentInputsLeavesTheTranscriptAndTheCompositePiece() throws {
    let workspace = makeWorkspace()
    defer { cleanUp(workspace) }
    let journal = TeardownJournal(workspace: workspace)
    let id = Build.jobID(1)
    let video = try writeArtifact("video.mp4", of: id, in: workspace)
    let chat = try writeArtifact("chat.json", of: id, in: workspace)
    let piece = try writeArtifact("piece-0.mp4", of: id, in: workspace)

    journal.removeSpentInputs(of: assembleReadyJob(
      workspace, videoArtifact: video, chatArtifact: chat, compositeArtifact: piece))

    #expect(!FileManager.default.fileExists(atPath: video.path),
            "control: the call must actually have removed something")
    #expect(FileManager.default.fileExists(atPath: chat.path),
            "the chat transcript is not spent by assemble")
    #expect(FileManager.default.fileExists(atPath: piece.path),
            "the composite's piece is half the delivery, not a spent input")
  }

  /// Preserve delivered artifacts outside workspace. Also delete an internal control to rule
  /// out no-op cleanup.
  @Test func spentInputsRefusesAPathOutsideTheJobWorkspace() throws {
    let workspace = makeWorkspace()
    defer { cleanUp(workspace) }
    let journal = TeardownJournal(workspace: workspace)
    let id = Build.jobID(1)

    let delivered = workspace.root.appending(path: "Movies-render.mp4")
    try Data("x".utf8).write(to: delivered)
    let video = try writeArtifact("video.mp4", of: id, in: workspace)

    journal.removeSpentInputs(of: assembleReadyJob(
      workspace, videoArtifact: video, renderArtifact: delivered))

    #expect(FileManager.default.fileExists(atPath: delivered.path),
            "a render already moved out of the workspace must survive")
    #expect(!FileManager.default.fileExists(atPath: video.path),
            "control: the call must actually have removed something")
  }

  /// User-immutable input forces a real removal failure that must be journaled.
  @Test func spentInputsJournalsWhatItCouldNotRemove() throws {
    let workspace = makeWorkspace()
    defer { cleanUp(workspace) }
    let journal = TeardownJournal(workspace: workspace)
    let id = Build.jobID(1)
    let stuck = try writeArtifact("video.mp4", of: id, in: workspace)
    try #require(
      chflags(stuck.path, UInt32(UF_IMMUTABLE)) == 0,
      "precondition: chflags must succeed to force the failure this test is after")
    defer { chflags(stuck.path, 0) }

    journal.removeSpentInputs(of: assembleReadyJob(workspace, videoArtifact: stuck))

    #expect(FileManager.default.fileExists(atPath: stuck.path),
            "precondition: the removal must genuinely have failed")
    let text = contents(of: workspace)
    #expect(text.contains(id.rawValue.uuidString), "should name the job; was: \(text)")
    #expect(text.contains("video.mp4"), "should name the file; was: \(text)")
    #expect(text.contains("assemble"), "should say what spent it; was: \(text)")
  }

  /// Nil artifacts must not generate spurious cleanup failures.
  @Test func spentInputsRecordsNothingWhenThereIsNothingToDrop() throws {
    let workspace = makeWorkspace()
    defer { cleanUp(workspace) }
    let journal = TeardownJournal(workspace: workspace)

    journal.removeSpentInputs(of: assembleReadyJob(workspace))

    #expect(
      !FileManager.default.fileExists(atPath: workspace.teardownFailureLog.path),
      "a job with no spent inputs must leave no failure record")
  }
}
