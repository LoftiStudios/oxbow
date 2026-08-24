import Foundation
import Testing
@testable import OxbowKit

@Suite("QueueEngine", .serialized)
struct QueueEngineTests {

  private func makeRoot() -> URL {
    URL(filePath: NSTemporaryDirectory()).appending(path: "oxbow-engine-\(UUID().uuidString)")
  }

  /// The queue file lives *outside* the workspace root — see
  /// `Configuration.store`. Derived from `root` rather than random so
  /// `cleanUp` can find it again from the one value the tests hold on to.
  private func storeURL(for root: URL) -> URL {
    root.deletingLastPathComponent().appending(path: "\(root.lastPathComponent)-queue.json")
  }

  private func makeConfiguration(
    root: URL,
    makeProcess: @escaping @Sendable () -> HelperProcessing)
    -> QueueEngine.Configuration
  {
    QueueEngine.Configuration(
      helperExecutable: URL(filePath: "/usr/bin/true"),
      ffmpegPath: URL(filePath: "/usr/bin/true"),
      workspace: Workspace(root: root),
      store: QueueStore(fileURL: storeURL(for: root)),
      makeProcess: makeProcess)
  }

  private func makeEngine(
    _ makeProcess: @escaping @Sendable () -> HelperProcessing)
    -> (engine: QueueEngine, root: URL)
  {
    let root = makeRoot()
    return (QueueEngine(configuration: makeConfiguration(root: root, makeProcess: makeProcess)), root)
  }

  private func makeEngine(
    _ behaviour: FakeHelper.Behaviour)
    -> (engine: QueueEngine, root: URL)
  {
    makeEngine { FakeHelper(behaviour) }
  }

  private func cleanUp(_ root: URL) {
    try? FileManager.default.removeItem(at: root)
    try? FileManager.default.removeItem(at: storeURL(for: root))
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
      cleanUp(root)
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
      cleanUp(root)
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
  ///
  /// The property under test is that a **finished** job stays finished. Its
  /// chat artifact was an intermediate, deliberately discarded when the job
  /// completed; treating that absence as "needs redoing" made a job the user
  /// saw as Done re-download its chat on every launch, forever, discarding it
  /// again each time. See the design spec, §5.
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
    // is what actually exercises the `Reconciler` wiring in `start()`. Its
    // helper factory is a tripwire: a finished job must launch nothing at all.
    var restartConfiguration = configuration
    restartConfiguration.makeProcess = {
      Issue.record("a finished job must not relaunch any step on restart")
      return FakeHelper(.succeeds)
    }

    let restarted = QueueEngine(configuration: restartConfiguration)
    try await restarted.start()

    let reloaded = await restarted.currentJobs
    #expect(reloaded.count == 1)
    #expect(reloaded[0].title == "persisted")
    #expect(reloaded[0].status == .done, "a finished job must still be finished after a restart")
    #expect(reloaded[0].steps.allSatisfy { $0.status == .done })

    // The chat artifact was an intermediate. It was deleted when the job
    // finished, and the claim on it was dropped in the same breath — so
    // nothing is left pointing at a file that no longer exists.
    #expect(reloaded[0].steps[0].artifact == nil, "the discarded intermediate must not be claimed")
    #expect(reloaded[0].steps[1].artifact == renderDestination)
    #expect(
      FileManager.default.fileExists(atPath: renderDestination.path),
      "the file the user actually asked for must survive the restart")

    #expect(await restarted.isIdle, "there must be nothing left to do")

    await restarted.flush()
  }

  @Test func publishesSnapshotsAsWorkProgresses() async throws {
    let (engine, root) = makeEngine(.succeeds)
    let (template, renderDestination) = makeChatAndRenderTemplate()
    defer {
      cleanUp(root)
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
    defer { cleanUp(root) }

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
    defer { cleanUp(root) }

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
      cleanUp(root)
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
    defer { cleanUp(root) }

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

  /// The invariant this pins: **a step is `.done` only while the artifact it
  /// records still exists.** `jobs/<id>/` holds `artifacts/`, the intermediates
  /// handed between steps, so deleting a cancelled job's workspace wholesale
  /// destroyed the chat file a finished chat step still pointed at — and a
  /// later retry of the render then ran `-i <deleted path>` and surfaced a
  /// .NET file-not-found stack trace to the user.
  @Test func cancellingAJobKeepsAnIntermediateItsDoneStepStillClaims() async throws {
    let sequenced = SequencedBehaviours([.succeeds, .hangsUntilCancelled, .succeeds])
    let (engine, root) = makeEngine { FakeHelper(sequenced.next()) }
    let (template, renderDestination) = makeChatAndRenderTemplate()
    defer {
      cleanUp(root)
      try? FileManager.default.removeItem(at: renderDestination)
    }

    try await engine.start()
    await engine.enqueue(template, title: "test")

    // Wait for exactly the state the bug needs: the chat finished, the render
    // genuinely in flight.
    for _ in 0..<200 {
      let steps = await engine.currentJobs.first?.steps
      if steps?[0].status == .done, steps?[1].status == .running { break }
      try await Task.sleep(for: .milliseconds(10))
    }
    let before = try #require(await engine.currentJobs.first?.steps)
    #expect(before[0].status == .done, "precondition: the chat download must have finished")
    #expect(before[1].status == .running, "precondition: the render must be in flight")

    let jobID = try #require(await engine.currentJobs.first?.id)
    await engine.cancel(job: jobID)
    try await settle(engine)

    let afterCancel = try #require(await engine.currentJobs.first?.steps)
    #expect(afterCancel[0].status == .done)
    let chatArtifact = try #require(afterCancel[0].artifact)
    #expect(
      FileManager.default.fileExists(atPath: chatArtifact.path),
      "a .done step's artifact must not be deleted out from under it")

    // And the consequence that makes it matter: retrying the render works,
    // because its input is still there.
    await engine.retry(step: afterCancel[1].id)
    try await settle(engine)

    let final = try #require(await engine.currentJobs.first?.steps)
    #expect(final[1].status == .done, "the retried render must run against the surviving chat file")
    #expect(FileManager.default.fileExists(atPath: renderDestination.path))

    await engine.flush()
  }

  /// Spec §1.5: a step succeeded iff its artifact exists **and is non-empty**.
  /// A helper killed after opening its output file leaves a zero-byte file
  /// behind; existence alone reads that as a finished download and moves it to
  /// the user's folder.
  @Test func anEmptyArtifactIsNotASuccess() async throws {
    let (engine, root) = makeEngine(.leavesAnEmptyArtifact)
    let destination = URL(filePath: NSTemporaryDirectory())
      .appending(path: "render-\(UUID().uuidString).mp4")
    defer {
      cleanUp(root)
      try? FileManager.default.removeItem(at: destination)
    }

    try await engine.start()
    await engine.enqueue(
      .video(VideoRequest(videoID: "v", quality: "best", destination: destination)),
      title: "test")
    try await settle(engine)

    let step = try #require(await engine.currentJobs.first?.steps.first)
    guard case .failed(let failure) = step.status else {
      Issue.record("an empty artifact must not read as success, got \(step.status)")
      return
    }
    #expect(failure.kind == .noArtifact)
    #expect(
      !FileManager.default.fileExists(atPath: destination.path),
      "an empty file must never be moved to the user's folder")

    await engine.flush()
  }

  /// The same rule at the other site that applies it: load-time
  /// reconciliation. A `.done` step whose recorded artifact is a zero-byte
  /// leftover has nothing usable and must be redone.
  @Test func restartRequeuesADoneStepWhoseArtifactIsEmpty() async throws {
    let root = makeRoot()
    let (template, renderDestination) = makeChatAndRenderTemplate()
    defer {
      cleanUp(root)
      try? FileManager.default.removeItem(at: renderDestination)
    }

    // An artifact outside the workspace, so the launch sweep is not what
    // requeues it — emptiness is.
    let stale = URL(filePath: NSTemporaryDirectory())
      .appending(path: "oxbow-engine-\(UUID().uuidString)-chat.json")
    defer { try? FileManager.default.removeItem(at: stale) }
    FileManager.default.createFile(atPath: stale.path, contents: Data())

    var job = template.makeJob(
      id: JobID(rawValue: UUID()),
      title: "empty artifact",
      created: Date(timeIntervalSince1970: 0),
      nextStepID: { StepID(rawValue: UUID()) })
    job.steps[0].status = .done
    job.steps[0].artifact = stale
    try QueueStore(fileURL: storeURL(for: root)).save([job])

    let engine = QueueEngine(configuration: makeConfiguration(root: root) { FakeHelper(.succeeds) })
    try await engine.start()
    try await settle(engine)

    let steps = try #require(await engine.currentJobs.first?.steps)
    #expect(steps[0].status == .done, "the requeued chat download must have re-run")
    #expect(steps[0].artifact != stale, "the empty leftover must not still be claimed")
    #expect(steps[1].status == .done)

    await engine.flush()
  }

  /// The most common real restart: the app crashed mid-download. The step
  /// persisted as `.running` cannot resume, so it must come back as
  /// `.failed(.interrupted)` — and its dependent must neither run against a
  /// missing input nor be wedged, which retrying the interrupted step proves.
  @Test func restartInterruptsARunningStepAndReleasesItsDependent() async throws {
    let root = makeRoot()
    let (template, renderDestination) = makeChatAndRenderTemplate()
    defer {
      cleanUp(root)
      try? FileManager.default.removeItem(at: renderDestination)
    }

    var job = template.makeJob(
      id: JobID(rawValue: UUID()),
      title: "interrupted",
      created: Date(timeIntervalSince1970: 0),
      nextStepID: { StepID(rawValue: UUID()) })
    job.steps[0].status = .running
    try QueueStore(fileURL: storeURL(for: root)).save([job])

    let engine = QueueEngine(configuration: makeConfiguration(root: root) { FakeHelper(.succeeds) })
    try await engine.start()
    try await settle(engine)

    let afterStart = try #require(await engine.currentJobs.first?.steps)
    #expect(
      afterStart[0].status == .failed(StepFailure(kind: .interrupted, summary: "Interrupted")),
      "a step persisted as running died with the app; there is no resume")
    #expect(afterStart[0].artifact == nil)
    #expect(afterStart[1].status != .running, "the dependent must not run without its input")
    #expect(afterStart[1].status != .done)

    await engine.retry(step: afterStart[0].id)
    try await settle(engine)

    let final = try #require(await engine.currentJobs.first?.steps)
    #expect(final[0].status == .done)
    #expect(final[1].status == .done, "the dependent must be released once its input exists")

    await engine.flush()
  }
}
