import Darwin
import Foundation
import Testing

@testable import OxbowKit

/// Direct tests for the branches `QueueEngineTests` cannot reach.
///
/// Compaction needs a 256 KB failure log, and the create-versus-append split
/// needs the log to be absent and then present. Neither is reachable by
/// driving an engine, which is why this logic went untested until it had a
/// type of its own.
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

  /// The second entry must not truncate the first. This is the branch the
  /// implementation's own comment warns about: `createFile(atPath:contents:)`
  /// truncates, so falling through to it unconditionally would wipe the
  /// history the file exists to keep.
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

  /// Past `cap + cap/2`, the log is trimmed back to at most `cap`.
  ///
  /// Seeded directly rather than by repeated `record` calls: reaching 384 KB
  /// through the real path would take thousands of entries, and the property
  /// under test is the trimming, not how the bytes got there.
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

  /// Compaction drops whole lines, never a byte offset — a byte cut would
  /// leave a mangled first entry that reads as corruption rather than as
  /// "the older history was trimmed".
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
    // Every seeded line is identical, so the first surviving line looks the
    // same (a whole "y"*63) whether or not compaction actually ran — that
    // shape check alone can't tell a real trim from a no-op. The signal that
    // distinguishes them is size: compaction must have brought the file back
    // to at most `cap`, which only happens by dropping whole lines from the
    // front.
    #expect(
      text.utf8.count <= cap,
      "compaction should have fired and brought the log back to at most \(cap); was \(text.utf8.count)"
    )
    let first = try #require(text.split(separator: "\n").first)
    #expect(
      first.count == 63 || first.contains("trigger.mp4"),
      "the first surviving line must be whole, not a partial cut; was: \(first)")
  }

  /// Past `cap` but short of the `cap + cap/2` hysteresis threshold,
  /// compaction must not fire — it only fires once the log is meaningfully
  /// over, not the instant the cap is crossed, so that a low-volume file is
  /// not rewritten on every single append. Seeded at `cap + cap/4`, the
  /// reviewer's suggested midpoint: comfortably past `cap` (so a fixture
  /// that never approaches the cap couldn't accidentally pass this test
  /// either way) and comfortably short of `cap + cap/2`, so the assertion
  /// that the file is still larger than `cap` after `record` actually pins
  /// the threshold rather than being true regardless of where it sits.
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

  /// `removeStep` names what it could not remove. `UF_IMMUTABLE` is what
  /// forces a removal failure without root — the same technique
  /// `QueueEngineTests` uses, minus the engine.
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
}
