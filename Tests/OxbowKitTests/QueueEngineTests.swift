import Foundation
import Testing
@testable import OxbowKit

/// A helper that writes whatever the test tells it to and reports a chosen status.
actor FakeHelper: HelperProcessing {
  enum Behaviour: Sendable {
    case succeeds
    case failsWithoutArtifact(stderr: String)
    /// Blocks inside `run` until `cancel()` is called, then reports as
    /// killed by SIGTERM — mirrors a real helper that keeps running until
    /// it is signalled, so a test can reliably catch the step `.running`
    /// before cancelling it.
    case hangsUntilCancelled
  }

  private let behaviour: Behaviour
  private var isCancelled = false
  private var cancelContinuation: CheckedContinuation<Void, Never>?

  init(_ behaviour: Behaviour) { self.behaviour = behaviour }

  func run(
    _ launch: Launch,
    onOutput: @escaping @Sendable (ParsedLine) async -> Void)
    async throws -> RunResult
  {
    await onOutput(.status(StepProgress(phase: "Working", fraction: 0.5)))

    switch behaviour {
    case .succeeds:
      // The engine's success criterion is the artifact, so produce one.
      if let output = Self.outputPath(in: launch.arguments) {
        FileManager.default.createFile(atPath: output, contents: Data("x".utf8))
      }
      return RunResult(status: .exited(0), standardError: "")

    case .failsWithoutArtifact(let stderr):
      return RunResult(status: .exited(134), standardError: stderr)

    case .hangsUntilCancelled:
      await waitForCancellation()
      // SIGTERM: 15.
      return RunResult(status: .signalled(15), standardError: "")
    }
  }

  func cancel() async {
    isCancelled = true
    cancelContinuation?.resume()
    cancelContinuation = nil
  }

  private func waitForCancellation() async {
    if isCancelled { return }
    await withCheckedContinuation { continuation in
      cancelContinuation = continuation
    }
  }

  private static func outputPath(in arguments: [String]) -> String? {
    guard let index = arguments.firstIndex(of: "-o"), index + 1 < arguments.count else { return nil }
    return arguments[index + 1]
  }
}

@Suite("QueueEngine", .serialized)
struct QueueEngineTests {

  private func makeEngine(
    _ makeProcess: @escaping @Sendable () -> HelperProcessing)
    -> (engine: QueueEngine, root: URL)
  {
    let root = URL(filePath: NSTemporaryDirectory())
      .appending(path: "oxbow-engine-\(UUID().uuidString)")
    let engine = QueueEngine(configuration: .init(
      helperExecutable: URL(filePath: "/usr/bin/true"),
      ffmpegPath: URL(filePath: "/usr/bin/true"),
      workspace: Workspace(root: root),
      store: QueueStore(fileURL: root.appending(path: "queue.json")),
      makeProcess: makeProcess))
    return (engine, root)
  }

  private func makeEngine(
    _ behaviour: FakeHelper.Behaviour)
    -> (engine: QueueEngine, root: URL)
  {
    makeEngine { FakeHelper(behaviour) }
  }

  /// The render step's destination is deliberately outside `root`, mirroring
  /// real usage — the user's chosen destination is never inside the app's own
  /// workspace, and must survive `Workspace.removeAll()`'s sweep. Because it
  /// is outside `root`, it is not cleaned up by a `root`-only `defer`, so
  /// callers must remove `renderDestination` themselves.
  private func makeChatAndRenderTemplate() -> (template: JobTemplate, renderDestination: URL) {
    let destination = URL(filePath: NSTemporaryDirectory())
      .appending(path: "render-\(UUID().uuidString).mp4")
    let template = JobTemplate.chatAndRender(
      ChatRequest(videoID: "2844548319", format: .json),
      RenderRequest(destination: destination))
    return (template, destination)
  }

  /// Waits for the queue to stop having runnable work, or fails the test.
  private func settle(_ engine: QueueEngine) async throws {
    for _ in 0..<200 {
      if await engine.isIdle { return }
      try await Task.sleep(for: .milliseconds(25))
    }
    Issue.record("queue did not settle")
  }

  @Test func runsDependentStepsInOrderAndCompletesTheJob() async throws {
    let (engine, root) = makeEngine(.succeeds)
    let (template, renderDestination) = makeChatAndRenderTemplate()
    defer {
      try? FileManager.default.removeItem(at: root)
      try? FileManager.default.removeItem(at: renderDestination)
    }

    try await engine.start()
    await engine.enqueue(template, title: "test")
    try await settle(engine)

    let jobs = await engine.currentJobs
    #expect(jobs.count == 1)
    #expect(jobs[0].steps.allSatisfy { $0.status == .done })
    #expect(jobs[0].status == .done)

    // Cancels the debounced save timer so it cannot recreate the workspace
    // root after this test's `defer` has already removed it.
    await engine.flush()
  }

  /// The scenario the whole failure model exists for.
  @Test func aFailedDependencyBlocksItsDependent() async throws {
    let (engine, root) = makeEngine(.failsWithoutArtifact(
      stderr: "Unhandled exception. System.Exception: vod_manifest_restricted"))
    let (template, renderDestination) = makeChatAndRenderTemplate()
    defer {
      try? FileManager.default.removeItem(at: root)
      try? FileManager.default.removeItem(at: renderDestination)
    }

    try await engine.start()
    await engine.enqueue(template, title: "test")
    try await settle(engine)

    let steps = await engine.currentJobs[0].steps
    guard case .failed(let failure) = steps[0].status else {
      Issue.record("expected the chat download to fail")
      return
    }
    #expect(failure.summary == "This is a subscriber-only VOD.")
    #expect(steps[1].status == .blocked, "the render must not run")

    // Cancels the debounced save timer so it cannot recreate the workspace
    // root after this test's `defer` has already removed it.
    await engine.flush()
  }

  /// Exercises a genuine restart, not just `QueueStore` round-tripping
  /// (already covered in `QueueStoreTests`): a second, independent
  /// `QueueEngine` loads the first one's saved queue and reconciles it
  /// against disk. The store file lives outside `root` deliberately — see
  /// `Configuration.store`'s doc comment.
  @Test func persistsAcrossRestart() async throws {
    let root = URL(filePath: NSTemporaryDirectory())
      .appending(path: "oxbow-engine-\(UUID().uuidString)")
    let storeURL = URL(filePath: NSTemporaryDirectory())
      .appending(path: "oxbow-engine-store-\(UUID().uuidString).json")
    let (template, renderDestination) = makeChatAndRenderTemplate()
    defer {
      try? FileManager.default.removeItem(at: root)
      try? FileManager.default.removeItem(at: storeURL)
      try? FileManager.default.removeItem(at: renderDestination)
    }

    let configuration = QueueEngine.Configuration(
      helperExecutable: URL(filePath: "/usr/bin/true"),
      ffmpegPath: URL(filePath: "/usr/bin/true"),
      workspace: Workspace(root: root),
      store: QueueStore(fileURL: storeURL),
      makeProcess: { FakeHelper(.succeeds) })

    let engine = QueueEngine(configuration: configuration)
    try await engine.start()
    await engine.enqueue(template, title: "persisted")
    try await settle(engine)
    await engine.flush()

    // A genuinely new instance, not the same engine reloaded in place — this
    // is what actually exercises the `Reconciler` wiring in `start()`.
    let restarted = QueueEngine(configuration: configuration)
    try await restarted.start()

    let reloaded = await restarted.currentJobs
    #expect(reloaded.count == 1)
    #expect(reloaded[0].title == "persisted")

    // The chat step's artifact lived inside the workspace root, which
    // `start()` sweeps unconditionally, so Reconciler must not have trusted
    // the stale `.done` — and by the time `start()` returns, its trailing
    // `tick()` has already picked the now-`.queued` step back up, so this
    // can observe either state depending on how far that got.
    let chatStatus = reloaded[0].steps[0].status
    #expect(
      chatStatus == .queued || chatStatus == .running,
      "the swept chat artifact must have been requeued, not trusted as done")

    try await settle(restarted)

    let finalSteps = try #require(await restarted.currentJobs.first?.steps)
    #expect(finalSteps[0].status == .done, "the requeued chat download must re-run successfully")
    // The render step's artifact is `renderDestination`, outside `root` —
    // untouched by the sweep — so Reconciler must have left it `.done` as-is,
    // and it must never have been re-admitted (it isn't `.queued`).
    #expect(finalSteps[1].status == .done)

    await restarted.flush()
  }

  @Test func publishesSnapshotsAsWorkProgresses() async throws {
    let (engine, root) = makeEngine(.succeeds)
    let (template, renderDestination) = makeChatAndRenderTemplate()
    defer {
      try? FileManager.default.removeItem(at: root)
      try? FileManager.default.removeItem(at: renderDestination)
    }

    try await engine.start()

    let received = CollectedSnapshots()
    let observer = Task {
      for await snapshot in await engine.makeSnapshots() {
        await received.append(snapshot)
        if snapshot.first?.status == .done { break }
      }
    }

    await engine.enqueue(template, title: "test")
    try await settle(engine)
    observer.cancel()

    #expect(await received.count > 1, "expected more than one snapshot")

    // Cancels the debounced save timer so it cannot recreate the workspace
    // root after this test's `defer` has already removed it.
    await engine.flush()
  }

  /// Critical: `cancel(step:)` must never let the step read as `.failed`.
  /// Before this fix, the in-flight `finish` call raced the cancellation and
  /// always won, overwriting `.cancelled` with `.failed(signalled(...))`.
  @Test func cancellingARunningStepSettlesAsCancelledNotFailed() async throws {
    let (engine, root) = makeEngine(.hangsUntilCancelled)
    defer { try? FileManager.default.removeItem(at: root) }

    try await engine.start()
    await engine.enqueue(.chat(ChatRequest(videoID: "2844548319", format: .json)), title: "test")

    // `enqueue` runs `tick()` to completion synchronously before returning,
    // so the step is already `.running` here — no polling needed.
    let stepID = try #require(await engine.currentJobs.first?.steps.first?.id)
    #expect(await engine.currentJobs.first?.steps.first?.status == .running)

    await engine.cancel(step: stepID)
    try await settle(engine)

    #expect(await engine.currentJobs.first?.steps.first?.status == .cancelled)

    await engine.flush()
  }

  /// Critical: `cancel(job:)` must preserve steps that had already finished,
  /// and must not report the ones it kills as `.failed`.
  @Test func cancellingAJobKeepsFinishedStepsAndCancelsTheRest() async throws {
    let sequenced = SequencedBehaviours([.succeeds, .hangsUntilCancelled])
    let (engine, root) = makeEngine { FakeHelper(sequenced.next()) }
    defer { try? FileManager.default.removeItem(at: root) }

    try await engine.start()
    await engine.enqueue(
      .videoChatAndRender(
        VideoRequest(videoID: "v", quality: "best", destination: root.appending(path: "video.mp4")),
        ChatRequest(videoID: "2844548319", format: .json),
        RenderRequest(destination: root.appending(path: "render.mp4"))),
      title: "test")

    // Video and chat both contend for the `.network` slot, so only video
    // (first in step order) launches immediately; it succeeds via the fake's
    // first behaviour, which frees the slot for chat to start running with
    // the fake's second behaviour (hangs). Wait for exactly that state —
    // one finished step, one genuinely in flight — before cancelling.
    for _ in 0..<200 {
      let steps = await engine.currentJobs.first?.steps
      if steps?[0].status == .done, steps?[1].status == .running { break }
      try await Task.sleep(for: .milliseconds(10))
    }
    let steps = try #require(await engine.currentJobs.first?.steps)
    #expect(steps[0].status == .done, "precondition: video must have finished first")
    #expect(steps[1].status == .running, "precondition: chat must be genuinely in flight")

    let jobID = try #require(await engine.currentJobs.first?.id)
    await engine.cancel(job: jobID)
    try await settle(engine)

    let final = try #require(await engine.currentJobs.first?.steps)
    #expect(final[0].status == .done, "the already-finished download must keep its status")
    #expect(final[1].status == .cancelled, "the running step must be cancelled, not failed")
    #expect(final[2].status == .cancelled, "the still-queued render must also be cancelled")

    await engine.flush()
  }

  /// Important #5: `retry` had no coverage at all, which is exactly where
  /// both criticals lived. Asserts both halves of retry-in-place: the failed
  /// step requeues (and relaunches), and its blocked dependent is released.
  @Test func retryingAFailedStepRequeuesItAndReleasesItsBlockedDependent() async throws {
    let (engine, root) = makeEngine(.failsWithoutArtifact(stderr: "boom"))
    let (template, renderDestination) = makeChatAndRenderTemplate()
    defer {
      try? FileManager.default.removeItem(at: root)
      try? FileManager.default.removeItem(at: renderDestination)
    }

    try await engine.start()
    await engine.enqueue(template, title: "test")
    try await settle(engine)

    let steps = try #require(await engine.currentJobs.first?.steps)
    guard case .failed = steps[0].status else {
      Issue.record("expected the chat download to have failed")
      return
    }
    #expect(steps[1].status == .blocked)

    await engine.retry(step: steps[0].id)

    // `retry` runs `tick()` to completion synchronously before returning, so
    // both transitions are already visible here — no polling needed.
    let afterRetry = try #require(await engine.currentJobs.first?.steps)
    #expect(afterRetry[0].status == .running, "the failed step must requeue and relaunch")
    #expect(afterRetry[1].status == .queued, "the blocked dependent must be released")

    try await settle(engine)
    await engine.flush()
  }

  /// Critical 2 regression: a step that succeeds but whose finished file
  /// cannot be moved to its destination must fail — not read as done — and
  /// the artifact itself must survive, since `finish`'s own cleanup would
  /// otherwise be the thing that deletes the only copy.
  @Test func aFailedMoveFailsTheStepAndPreservesTheArtifact() async throws {
    let (engine, root) = makeEngine(.succeeds)
    defer { try? FileManager.default.removeItem(at: root) }

    try await engine.start()

    // Force `move` to fail deterministically (no timing dependency): create
    // a plain file where the destination's parent directory needs to be, so
    // `FileManager.createDirectory(at:withIntermediateDirectories:)` throws
    // instead of silently succeeding — a full disk or unwritable volume
    // fails the same way in production.
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let blocker = root.appending(path: "blocked")
    FileManager.default.createFile(atPath: blocker.path, contents: Data())
    let destination = blocker.appending(path: "output.mp4")

    await engine.enqueue(
      .video(VideoRequest(videoID: "v", quality: "best", destination: destination)),
      title: "test")
    try await settle(engine)

    let job = try #require(await engine.currentJobs.first)
    let step = try #require(job.steps.first)

    guard case .failed(let failure) = step.status else {
      Issue.record("expected the failed move to fail the step, got \(step.status)")
      return
    }
    guard case .moveFailed = failure.kind else {
      Issue.record("expected .moveFailed, got \(failure.kind)")
      return
    }
    #expect(job.status == .failed, "a failed move must not read as a finished job")

    // The one assertion that actually pins the data-loss fix: the artifact
    // `move` failed to relocate must still be sitting in the workspace,
    // proving `completeStep` did not treat this job as done and delete it.
    let artifact = Workspace(root: root).artifactsDirectory(job.id).appending(path: "video.mp4")
    #expect(
      FileManager.default.fileExists(atPath: artifact.path),
      "the only copy of the artifact must survive a failed move")

    await engine.flush()
  }
}
