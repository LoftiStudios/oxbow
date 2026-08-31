import Foundation
import Testing
@testable import OxbowKit

/// A 70-minute composite on a Mac nobody is touching used to lose to Energy
/// Saver: the work is a child process, and a child process is not something
/// the idle timer counts. These assert the decision — that the engine claims
/// the Mac exactly while it has work in flight, and gives it back afterwards
/// — because `ProcessInfo.beginActivity` itself has no effect a test can see.
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

  /// Nothing enqueued, nothing claimed. Stated because the opposite — an
  /// assertion taken at launch and held for the process's lifetime — is the
  /// easy wrong implementation, and it would keep a Mac awake forever behind
  /// an app someone left open.
  @Test func claimsNothingWhileTheQueueIsEmpty() async throws {
    let (engine, root, sleep) = makeEngine(.succeeds)
    defer { cleanUp(root) }

    try await engine.start()

    #expect(sleep.transitions.isEmpty)
    #expect(!sleep.isActive)
  }

  /// The whole point: held across a running job, released once it settles.
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

  /// Released on the failure path too. A step that fails still clears
  /// `running`, and an assertion that only came down on success would leak on
  /// exactly the runs a user is most likely to walk away from.
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

  /// Cancelling is the path where a leak would be invisible: the user thinks
  /// they stopped everything, the queue agrees, and the Mac quietly never
  /// sleeps again.
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

  /// Same for removal, which takes a different route out of `running` than
  /// cancellation does — it drops the entries itself rather than waiting for
  /// each kill to report back.
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

  /// Quitting with work in flight. `shutDown` deliberately leaves the steps
  /// `.running` in the saved queue so the reconciler can call them
  /// interrupted at the next launch — so the status is exactly the wrong
  /// thing to key the assertion on, and this proves it is keyed on the
  /// process table instead.
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

  /// Two steps of one job produce two claims, not one held across both: a
  /// step's completion empties `running` before the next one is admitted, and
  /// the `didSet` sees that intermediate state.
  ///
  /// **Recorded rather than fixed, because it cannot matter.** The gap is one
  /// actor turn with no suspension in it — microseconds — and the shortest
  /// idle-sleep Energy Saver will accept is a minute. Holding the assertion
  /// across the seam would mean tracking admissible-but-unstarted work, and
  /// that has a worse failure mode than this one: during `shutDown` nothing
  /// further is admitted, so a queue-based reading would stay awake for work
  /// that will never run. If this expectation ever fails because the flap is
  /// gone, that is an improvement — update it.
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

  /// The real assertion, exercised for its idempotence contract: `didSet`
  /// fires on every mutation of `running`, so `setActive` is handed long runs
  /// of the same value and must not stack tokens or over-release one.
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
