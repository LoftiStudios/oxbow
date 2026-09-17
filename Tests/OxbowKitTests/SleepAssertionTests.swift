import Foundation
import Testing
@testable import OxbowKit

/// Assert engine sleep-claim transitions through an injected sink; OS idle-sleep effects are
/// not directly testable.
@Suite("Sleep assertion", .serialized)
struct SleepAssertionTests {

  private func makeRoot() -> URL {
    URL(filePath: NSTemporaryDirectory()).appending(path: "oxbow-sleep-\(UUID().uuidString)")
  }

  private func storeURL(for root: URL) -> URL {
    root.deletingLastPathComponent().appending(path: "\(root.lastPathComponent)-queue.json")
  }

  private func makeEngine(
    _ behaviour: FakeHelper.Behaviour)
    -> (engine: QueueEngine, root: URL, sleep: SpySleepAssertion)
  {
    let root = makeRoot()
    let sleep = SpySleepAssertion()
    let configuration = QueueEngine.Configuration(
      helperExecutable: URL(filePath: "/usr/bin/true"),
      ffmpegPath: URL(filePath: "/usr/bin/false"),
      workspace: Workspace(root: root),
      store: QueueStore(fileURL: storeURL(for: root)),
      makeProcess: { FakeHelper(behaviour) },
      sleepAssertion: sleep)
    return (QueueEngine(configuration: configuration), root, sleep)
  }

  private func cleanUp(_ root: URL) {
    try? FileManager.default.removeItem(at: root)
    try? FileManager.default.removeItem(at: storeURL(for: root))
  }

  private func settle(_ engine: QueueEngine) async throws {
    for _ in 0..<200 {
      if await engine.isIdle { return }
      try await Task.sleep(for: .milliseconds(25))
    }
    Issue.record("queue did not settle")
  }

  private func videoTemplate(into root: URL) -> JobTemplate {
    JobTemplate(media: .video(VideoRequest(
      videoID: "1", quality: "", destination: root.appending(path: "out.mp4"))))
  }

  /// An idle app must not hold a sleep assertion.
  @Test func claimsNothingWhileTheQueueIsEmpty() async throws {
    let (engine, root, sleep) = makeEngine(.succeeds)
    defer { cleanUp(root) }

    try await engine.start()

    #expect(sleep.transitions.isEmpty)
    #expect(!sleep.isActive)
  }

  /// Hold while work runs and release when it settles.
  @Test func holdsTheMacAwakeForAJobAndReleasesItAfterwards() async throws {
    let (engine, root, sleep) = makeEngine(.succeeds)
    defer { cleanUp(root) }

    try await engine.start()
    await engine.enqueue(videoTemplate(into: root), title: "t")
    try await settle(engine)

    #expect(sleep.transitions == [true, false])
    #expect(!sleep.isActive)
    await engine.flush()
  }

  /// Failures release the assertion too.
  @Test func releasesTheMacWhenAJobFails() async throws {
    let (engine, root, sleep) = makeEngine(.failsWithoutArtifact(stderr: "boom"))
    defer { cleanUp(root) }

    try await engine.start()
    await engine.enqueue(videoTemplate(into: root), title: "t")
    try await settle(engine)

    #expect(await engine.currentJobs.first?.status == .failed, "precondition")
    #expect(!sleep.isActive)
    await engine.flush()
  }

  /// Cancellation must release the assertion.
  @Test func releasesTheMacWhenARunningJobIsCancelled() async throws {
    let (engine, root, sleep) = makeEngine(.hangsUntilCancelled)
    defer { cleanUp(root) }

    try await engine.start()
    await engine.enqueue(videoTemplate(into: root), title: "t")
    try await waitUntil { sleep.isActive }
    #expect(sleep.isActive, "precondition: the running step should hold the Mac awake")

    let job = try #require(await engine.currentJobs.first)
    await engine.cancel(job: job.id)

    try await waitUntil { !sleep.isActive }
    #expect(!sleep.isActive)
    await engine.flush()
  }

  /// Removal clears running entries through a separate path and must also release.
  @Test func releasesTheMacWhenARunningJobIsRemoved() async throws {
    let (engine, root, sleep) = makeEngine(.hangsUntilCancelled)
    defer { cleanUp(root) }

    try await engine.start()
    await engine.enqueue(videoTemplate(into: root), title: "t")
    try await waitUntil { sleep.isActive }

    let job = try #require(await engine.currentJobs.first)
    await engine.remove(jobs: [job.id])

    #expect(!sleep.isActive)
    await engine.flush()
  }

  /// Shutdown leaves persisted step status running but empties active processes; sleep claims
  /// must follow the latter.
  @Test func releasesTheMacOnShutDown() async throws {
    let (engine, root, sleep) = makeEngine(.hangsUntilCancelled)
    defer { cleanUp(root) }

    try await engine.start()
    await engine.enqueue(videoTemplate(into: root), title: "t")
    try await waitUntil { sleep.isActive }

    await engine.shutDown()

    try await waitUntil { !sleep.isActive }
    #expect(!sleep.isActive)
  }

  /// Sequential steps briefly release/reacquire within one unsuspended actor turn. This
  /// harmless gap keeps claims tied to running processes rather than work shutdown will never
  /// admit.
  @Test func flapsBetweenTheStepsOfAMultiStepJobAndThatIsHarmless() async throws {
    let destination = URL(filePath: NSTemporaryDirectory())
      .appending(path: "render-\(UUID().uuidString).mp4")
    let (engine, root, sleep) = makeEngine(.succeeds)
    defer {
      cleanUp(root)
      try? FileManager.default.removeItem(at: destination)
    }

    try await engine.start()
    await engine.enqueue(
      JobTemplate(
        chat: ChatRequest(videoID: "2844548319", format: .json),
        render: RenderRequest(destination: destination)),
      title: "t")
    try await settle(engine)

    #expect(await engine.currentJobs.first?.status == .done, "precondition")
    #expect(sleep.transitions == [true, false, true, false])
    #expect(!sleep.isActive)
    await engine.flush()
  }

  /// Repeated values must neither stack activity tokens nor over-release them.
  @Test func theRealAssertionIsIdempotentInBothDirections() {
    let assertion = SystemSleepAssertion()

    assertion.setActive(false)
    assertion.setActive(true)
    assertion.setActive(true)
    assertion.setActive(false)
    assertion.setActive(false)
    assertion.setActive(true)
    assertion.setActive(false)
  }

  private func waitUntil(
    _ condition: @Sendable () -> Bool,
    sourceLocation: SourceLocation = #_sourceLocation) async throws
  {
    for _ in 0..<200 {
      if condition() { return }
      try await Task.sleep(for: .milliseconds(25))
    }
    Issue.record("condition never became true", sourceLocation: sourceLocation)
  }
}
