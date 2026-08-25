import Darwin
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
      // Distinct from helperExecutable so a test can tell which binary a step
      // was launched against. Never executed — FakeHelper stands in for both.
      ffmpegPath: URL(filePath: "/usr/bin/false"),
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
    let template = JobTemplate(
      chat: ChatRequest(videoID: "2844548319", format: .json),
      render: RenderRequest(destination: destination))
    return (template, destination)
  }

  /// The helper's narrative output is the only record of what a step was
  /// doing. Discarding it is why a helper that finished its work and then
  /// hung could only be diagnosed by sampling the process.
  ///
  /// Asserted on a FAILING step deliberately: a job that reaches `.done` has
  /// its whole workspace removed, log included, which is right — there is
  /// nothing to diagnose about work that succeeded and was delivered. The
  /// log has to survive exactly where someone would go looking for it.
  @Test func keepsTheHelpersNarrativeOutputForAFailedStep() async throws {
    let (engine, root) = makeEngine(.failsWithoutArtifact(stderr: "boom"))
    defer { cleanUp(root) }
    let workspace = Workspace(root: root)

    try await engine.start()
    await engine.enqueue(
      JobTemplate(media: .video(VideoRequest(
        videoID: "1", quality: "",
        destination: root.appending(path: "out.mp4")))),
      title: "t")
    try await settle(engine)

    let job = try #require(await engine.currentJobs.first)
    let step = try #require(job.steps.first)
    let contents = (try? String(contentsOf: workspace.logFile(job: job.id, step: step.id), encoding: .utf8)) ?? ""

    #expect(contents.contains("Fetching video info"), "log line missing; log was: \(contents)")
    #expect(contents.contains("frame= 42"), "ffmpeg line missing; log was: \(contents)")
  }

  /// Status lines drive the progress bar and arrive by the hundreds — one per
  /// render frame batch. Writing them to the log too would bury the handful of
  /// lines that actually say what a step was doing when it stopped.
  @Test func statusLinesAreNotWrittenToTheLog() async throws {
    let (engine, root) = makeEngine(.failsWithoutArtifact(stderr: "boom"))
    defer { cleanUp(root) }
    let workspace = Workspace(root: root)

    try await engine.start()
    await engine.enqueue(
      JobTemplate(media: .video(VideoRequest(
        videoID: "1", quality: "",
        destination: root.appending(path: "out.mp4")))),
      title: "t")
    try await settle(engine)

    let job = try #require(await engine.currentJobs.first)
    let step = try #require(job.steps.first)
    let contents = (try? String(contentsOf: workspace.logFile(job: job.id, step: step.id), encoding: .utf8)) ?? ""

    #expect(!contents.isEmpty, "precondition: the log should have narrative lines in it")
    #expect(!contents.contains("Working"), "a status line leaked into the log")
  }

  /// The flip side, stated so it is a decision rather than an accident: a job
  /// that succeeded has nothing left to explain, and its log goes with the
  /// workspace it lived in.
  @Test func aSucceedingJobTakesItsLogWithItsWorkspace() async throws {
    let (engine, root) = makeEngine(.succeeds)
    defer { cleanUp(root) }
    let workspace = Workspace(root: root)

    try await engine.start()
    await engine.enqueue(
      JobTemplate(media: .video(VideoRequest(
        videoID: "1", quality: "",
        destination: root.appending(path: "out.mp4")))),
      title: "t")
    try await settle(engine)

    let job = try #require(await engine.currentJobs.first)
    let step = try #require(job.steps.first)
    #expect(job.status == .done)
    #expect(!FileManager.default.fileExists(atPath: workspace.logFile(job: job.id, step: step.id).path))
  }


  /// Retry is a from-scratch restart, not a resume — nothing in this stack can
  /// resume — so the real question is whether a cancelled job comes back to
  /// life at all. Cancelling settles every step as `.cancelled`, and this
  /// asserts the whole job runs through to `.done` afterwards rather than
  /// restarting one step and stalling.
  @Test func aCancelledMultiStepJobCanBeRetriedAndRunsToCompletion() async throws {
    let (engine, root) = makeEngine(.succeeds)
    let (template, renderDestination) = makeChatAndRenderTemplate()
    defer {
      cleanUp(root)
      try? FileManager.default.removeItem(at: renderDestination)
    }

    try await engine.start()
    await engine.enqueue(template, title: "test")

    let job = try #require(await engine.currentJobs.first)
    await engine.cancel(job: job.id)
    #expect(await engine.currentJobs.first?.status == .cancelled, "precondition")

    await engine.retry(job: job.id)
    try await settle(engine)

    let retried = try #require(await engine.currentJobs.first)
    #expect(retried.status == .done)
    #expect(retried.steps.allSatisfy { $0.status == .done })
    await engine.flush()
  }

  // MARK: - Removing jobs

  /// The queue had no way to forget anything: every job ever enqueued stayed
  /// in the list forever, which is what made the window read as an append-only
  /// log rather than a queue.
  @Test func removesASettledJobAndLeavesTheOthers() async throws {
    let (engine, root) = makeEngine(.succeeds)
    defer { cleanUp(root) }

    try await engine.start()
    await engine.enqueue(
      JobTemplate(media: .video(VideoRequest(
        videoID: "1", quality: "", destination: root.appending(path: "a.mp4")))),
      title: "a")
    await engine.enqueue(
      JobTemplate(media: .video(VideoRequest(
        videoID: "2", quality: "", destination: root.appending(path: "b.mp4")))),
      title: "b")
    try await settle(engine)

    let first = try #require(await engine.currentJobs.first { $0.title == "a" })
    await engine.remove(jobs: [first.id])

    let remaining = await engine.currentJobs
    #expect(remaining.map(\.title) == ["b"])
    await engine.flush()
  }

  /// Removing a job removes what it left behind in our workspace — the logs
  /// and any intermediates a failure kept around. Otherwise "clear the list"
  /// quietly leaks disk forever.
  @Test func removingAJobDeletesItsWorkspace() async throws {
    let (engine, root) = makeEngine(.failsWithoutArtifact(stderr: "boom"))
    defer { cleanUp(root) }
    let workspace = Workspace(root: root)

    try await engine.start()
    await engine.enqueue(
      JobTemplate(media: .video(VideoRequest(
        videoID: "1", quality: "", destination: root.appending(path: "out.mp4")))),
      title: "t")
    try await settle(engine)

    let job = try #require(await engine.currentJobs.first)
    #expect(FileManager.default.fileExists(atPath: workspace.jobDirectory(job.id).path),
            "precondition: a failed job keeps its workspace")

    await engine.remove(jobs: [job.id])

    #expect(!FileManager.default.fileExists(atPath: workspace.jobDirectory(job.id).path))
    await engine.flush()
  }

  /// **The file the user asked for is not ours to delete.** Removing a row is
  /// housekeeping on our own queue; the download in their Downloads folder is
  /// the whole point of the app and survives untouched.
  @Test func removingAJobLeavesTheDeliveredFileAlone() async throws {
    let (engine, root) = makeEngine(.succeeds)
    let destination = URL(filePath: NSTemporaryDirectory())
      .appending(path: "delivered-\(UUID().uuidString).mp4")
    defer {
      cleanUp(root)
      try? FileManager.default.removeItem(at: destination)
    }

    try await engine.start()
    await engine.enqueue(
      JobTemplate(media: .video(VideoRequest(
        videoID: "1", quality: "", destination: destination))),
      title: "t")
    try await settle(engine)

    let job = try #require(await engine.currentJobs.first)
    #expect(FileManager.default.fileExists(atPath: destination.path),
            "precondition: the job delivered its file")

    await engine.remove(jobs: [job.id])

    #expect(await engine.currentJobs.isEmpty)
    #expect(FileManager.default.fileExists(atPath: destination.path))
    await engine.flush()
  }

  /// Removing something still running has to kill its helper first. Dropping
  /// the row without cancelling would orphan `TwitchDownloaderCLI` and the
  /// FFmpeg it spawned, still writing into a workspace we just deleted — the
  /// exact failure `shutDown()` exists to prevent, reached by another door.
  @Test func removingARunningJobCancelsItsHelperFirst() async throws {
    let (engine, root) = makeEngine(.hangsUntilCancelled)
    defer { cleanUp(root) }

    try await engine.start()
    await engine.enqueue(
      JobTemplate(media: .video(VideoRequest(
        videoID: "1", quality: "", destination: root.appending(path: "out.mp4")))),
      title: "t")

    // Wait for it to actually be running, so this is a removal mid-flight and
    // not a removal of something still queued.
    var job: Job?
    for _ in 0..<200 {
      if let candidate = await engine.currentJobs.first, candidate.status == .running {
        job = candidate
        break
      }
      try await Task.sleep(for: .milliseconds(25))
    }
    let running = try #require(job, "job never reached .running")

    await engine.remove(jobs: [running.id])

    #expect(await engine.currentJobs.isEmpty)
    #expect(await engine.isIdle, "the helper was left running after its job was removed")
    await engine.flush()
  }

  /// Removal is persisted, not just published: a removed job must not come
  /// back at the next launch.
  @Test func aRemovedJobIsNotInTheSavedQueue() async throws {
    let (engine, root) = makeEngine(.succeeds)
    defer { cleanUp(root) }

    try await engine.start()
    await engine.enqueue(
      JobTemplate(media: .video(VideoRequest(
        videoID: "1", quality: "", destination: root.appending(path: "out.mp4")))),
      title: "t")
    try await settle(engine)

    let job = try #require(await engine.currentJobs.first)
    await engine.remove(jobs: [job.id])
    await engine.flush()

    let reloaded = try QueueStore(fileURL: storeURL(for: root)).load()
    #expect(reloaded.isEmpty)
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

  /// A composite step runs FFmpeg directly rather than the C# helper: both
  /// the executable and the stdout dialect follow the step kind.
  @Test func aCompositeStepRunsFFmpegRatherThanTheHelper() async throws {
    let helper = FakeHelper(.succeeds)
    let (engine, root) = makeEngine { helper }
    defer { cleanUp(root) }

    let template = JobTemplate(
      media: .video(VideoRequest(videoID: "v", quality: "1080p60")),
      render: RenderRequest(),
      composite: CompositeRequest(
        framerate: 60,
        bitrateMbps: 8,
        duration: .seconds(60),
        destination: root.appending(path: "out.mp4")))

    try await engine.start()
    await engine.enqueue(template, title: "t")
    try await settle(engine)

    let launches = await helper.launches
    let composite = try #require(launches.first { $0.dialect != .helper })
    #expect(composite.executable == URL(filePath: "/usr/bin/false"))
    #expect(composite.dialect == .ffmpeg(duration: .seconds(60)))

    // Every other step still runs the C# helper.
    #expect(launches.filter { $0.dialect == .helper }.allSatisfy {
      $0.executable == URL(filePath: "/usr/bin/true")
    })

    await engine.flush()
  }

  /// The "one file out" promise the whole feature rests on: a composite job's
  /// video and chat render are intermediates shaped exactly like real intake
  /// output (`destination: nil`) and must never reach the user's chosen
  /// folder, while the composite itself is delivered to its own destination.
  @Test func aCompositeJobDeliversExactlyOneFile() async throws {
    let (engine, root) = makeEngine(.succeeds)
    defer { cleanUp(root) }

    let destination = root.appending(path: "out.mp4")
    let template = JobTemplate(
      media: .video(VideoRequest(videoID: "v", quality: "1080p60")),
      render: RenderRequest(),
      composite: CompositeRequest(
        framerate: 60,
        bitrateMbps: 8,
        duration: .seconds(60),
        destination: destination))

    try await engine.start()
    await engine.enqueue(template, title: "t")
    try await settle(engine)

    let job = try #require(await engine.currentJobs.first)
    #expect(job.status == .done)
    #expect(job.steps.allSatisfy { $0.status == .done })

    // The video, chat, and render steps carried no destination of their own,
    // so each is an intermediate: deleted with the job's workspace, its claim
    // dropped in the same breath. Only the composite was actually moved out.
    for step in job.steps {
      switch step.kind {
      case .composite:
        #expect(step.artifact == destination)
      case .downloadVideo, .downloadClip, .downloadChat, .renderChat:
        #expect(step.artifact == nil, "an intermediate must not be claimed")
      }
    }

    #expect(FileManager.default.fileExists(atPath: destination.path))

    // Nothing else reached disk under root: exactly the composite's own
    // file, nowhere else — the video and render never left the workspace
    // that was just swept.
    let enumerator = FileManager.default.enumerator(atPath: root.path)
    let delivered = (enumerator?.allObjects as? [String] ?? []).filter { $0.hasSuffix(".mp4") }
    #expect(delivered == ["out.mp4"])

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
      // Distinct from helperExecutable so a test can tell which binary a step
      // was launched against. Never executed — FakeHelper stands in for both.
      ffmpegPath: URL(filePath: "/usr/bin/false"),
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

  /// A composite job keeps its downloaded video as an intermediate exactly as
  /// a render already keeps its chat file: `destination: nil` discards it
  /// with the rest of the workspace once the job finishes, rather than
  /// delivering a stray file the user never asked for. Mirrors
  /// `persistsAcrossRestart`'s check on the chat artifact, minus the restart.
  @Test func aVideoWithNoDestinationStaysInTheWorkspace() async throws {
    let (engine, root) = makeEngine(.succeeds)
    defer { cleanUp(root) }

    try await engine.start()
    await engine.enqueue(
      JobTemplate(media: .video(VideoRequest(videoID: "1", quality: "", destination: nil))),
      title: "t")
    try await settle(engine)

    let job = try #require(await engine.currentJobs.first)
    #expect(job.status == .done)

    // The video was an intermediate. It was deleted when the job finished,
    // and the claim on it was dropped in the same breath — so nothing is left
    // pointing at a file that no longer exists.
    #expect(job.steps[0].artifact == nil, "the discarded intermediate must not be claimed")

    // Nothing reached the user's folder: nil means "discard with the job,"
    // exactly as it already does for a chat file.
    let enumerator = FileManager.default.enumerator(atPath: root.path)
    let delivered = (enumerator?.allObjects as? [String] ?? []).filter { $0.hasSuffix(".mp4") }
    #expect(delivered.isEmpty)
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
    await engine.enqueue(JobTemplate(chat: ChatRequest(videoID: "2844548319", format: .json)), title: "test")

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
    let sequenced = SequencedBehaviours([.succeeds, .hangsUntilCancelled, .hangsUntilCancelled])
    let (engine, root) = makeEngine { FakeHelper(sequenced.next()) }
    defer { cleanUp(root) }

    try await engine.start()
    await engine.enqueue(
      JobTemplate(
        media: .video(VideoRequest(videoID: "v", quality: "best", destination: root.appending(path: "video.mp4"))),
        chat: ChatRequest(videoID: "2844548319", format: .json),
        render: RenderRequest(destination: root.appending(path: "render.mp4")),
        composite: CompositeRequest(
          framerate: 60, bitrateMbps: 8, duration: .seconds(60),
          destination: root.appending(path: "composite.mp4"))),
      title: "test")

    // `makeJob` appends chat and render before the media step (see the
    // load-bearing-order note there and docs/design/compositing.md §6), so
    // chat — depending on nothing — is the only step admissible at t0 and
    // launches first; it succeeds via the fake's first behaviour. That frees
    // `.network`, and with chat now `.done`, render's one dependency is
    // satisfied: render (`.compute`) and the video download (`.network`)
    // share no resource class, so both are admitted and launched in the same
    // tick, hanging via the fake's remaining two behaviours. The composite
    // depends on both and so is left genuinely still queued. Wait for
    // exactly that state before cancelling.
    for _ in 0..<200 {
      let steps = await engine.currentJobs.first?.steps
      if steps?[0].status == .done, steps?[1].status == .running, steps?[2].status == .running {
        break
      }
      try await Task.sleep(for: .milliseconds(10))
    }
    let steps = try #require(await engine.currentJobs.first?.steps)
    #expect(steps[0].status == .done, "precondition: chat must have finished first")
    #expect(steps[1].status == .running, "precondition: render must be genuinely in flight")
    #expect(steps[2].status == .running, "precondition: video must be genuinely in flight")
    #expect(steps[3].status == .queued, "precondition: composite must still be queued")

    let jobID = try #require(await engine.currentJobs.first?.id)
    await engine.cancel(job: jobID)
    try await settle(engine)

    let final = try #require(await engine.currentJobs.first?.steps)
    #expect(final[0].status == .done, "the already-finished download must keep its status")
    #expect(final[1].status == .cancelled, "the running render must be cancelled, not failed")
    #expect(final[2].status == .cancelled, "the running video must be cancelled, not failed")
    #expect(final[3].status == .cancelled, "the still-queued composite must also be cancelled")

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
      JobTemplate(media: .video(VideoRequest(videoID: "v", quality: "best", destination: destination))),
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
      JobTemplate(media: .video(VideoRequest(videoID: "v", quality: "best", destination: destination))),
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

  // MARK: - Shutdown

  /// The orphaned-helper bug: quitting used to flush the queue and exit
  /// without ever signalling the running helpers, so `TwitchDownloaderCLI`
  /// and its FFmpeg outlived the app.
  ///
  /// Asserts both halves of the fix at once, because they are one decision:
  /// the helper is signalled, *and* the step it was running is left `.running`
  /// in the saved queue so the next launch reconciles it to
  /// `.failed(.interrupted)` — the design's model for interrupted work — 
  /// rather than to a `.cancelled` the user never asked for or a
  /// `.failed(.signalled(SIGTERM))` that would read as a crash.
  @Test func shutDownSignalsTheRunningHelperAndLeavesItsStepForTheReconciler() async throws {
    // The same instance every time, so the test can interrogate the one the
    // engine actually launched. Safe here: only one step ever launches.
    let helper = FakeHelper(.hangsUntilCancelled)
    let root = makeRoot()
    defer { cleanUp(root) }
    let engine = QueueEngine(configuration: makeConfiguration(root: root) { helper })

    try await engine.start()
    await engine.enqueue(
      JobTemplate(media: .video(VideoRequest(
        videoID: "v",
        quality: "best",
        destination: root.appending(path: "video.mp4")))),
      title: "test")

    for _ in 0..<200 {
      if await engine.currentJobs.first?.steps.first?.status == .running { break }
      try await Task.sleep(for: .milliseconds(10))
    }
    #expect(
      await engine.currentJobs.first?.steps.first?.status == .running,
      "precondition: a step must be genuinely in flight")

    await engine.shutDown()

    #expect(
      await helper.wasCancelled,
      "the quit must signal the helper, or its process group outlives the app")

    let saved = try QueueStore(fileURL: storeURL(for: root)).load()
    #expect(
      saved.first?.steps.first?.status == .running,
      "an interrupted step must persist as running for the reconciler to read")

    let relaunched = QueueEngine(configuration: makeConfiguration(root: root) { FakeHelper(.succeeds) })
    try await relaunched.start()
    let reconciled = try #require(await relaunched.currentJobs.first?.steps.first)
    #expect(
      reconciled.status == .failed(StepFailure(kind: .interrupted, summary: "Interrupted")),
      "the next launch must report the quit as interrupted work")
    await relaunched.flush()
  }

  /// A quit is held open by `.terminateLater`, so the window is still alive
  /// while `shutDown()` runs and the user can still reach the intake sheet.
  /// Admitting anything in that window would spawn a helper the app is about
  /// to walk out on — exactly the orphan this change exists to remove.
  @Test func nothingNewLaunchesOnceTheQuitIsUnderWay() async throws {
    let (engine, root) = makeEngine(.hangsUntilCancelled)
    defer { cleanUp(root) }

    try await engine.start()
    await engine.shutDown()

    await engine.enqueue(
      JobTemplate(media: .video(VideoRequest(
        videoID: "v",
        quality: "best",
        destination: root.appending(path: "video.mp4")))),
      title: "late")

    #expect(
      await engine.currentJobs.first?.steps.first?.status == .queued,
      "a quit must not launch work it is about to abandon")
  }

  /// The automated form of the manual check on this bug. `FakeHelper` can only
  /// prove `cancel()` was called; only a real `HelperProcess` proves the
  /// signal reaches the whole *process group*, which is the half that keeps
  /// FFmpeg from being orphaned alongside the CLI that spawned it.
  ///
  /// The fixture stands in for that pair: a helper with a child that outlives
  /// it unless the group is signalled. Both pids must be gone after the quit.
  @Test func shutDownReapsTheWholeProcessGroupOfARealHelper() async throws {
    let root = makeRoot()
    defer { cleanUp(root) }

    let fixtures = URL(filePath: NSTemporaryDirectory())
      .appending(path: "oxbow-shutdown-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: fixtures, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: fixtures) }

    let pidFile = fixtures.appending(path: "pids")
    let script = fixtures.appending(path: "helper.sh")
    try """
      #!/bin/sh
      sleep 300 &
      printf '%s %s\\n' "$$" "$!" > "\(pidFile.path)"
      sleep 300
      """.write(to: script, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)

    let engine = QueueEngine(configuration: QueueEngine.Configuration(
      helperExecutable: script,
      // Distinct from helperExecutable so a test can tell which binary a step
      // was launched against. Never executed — FakeHelper stands in for both.
      ffmpegPath: URL(filePath: "/usr/bin/false"),
      workspace: Workspace(root: root),
      store: QueueStore(fileURL: storeURL(for: root)),
      makeProcess: { HelperProcess() }))

    try await engine.start()
    await engine.enqueue(
      JobTemplate(media: .video(VideoRequest(
        videoID: "v",
        quality: "best",
        destination: root.appending(path: "video.mp4")))),
      title: "test")

    var pids: [pid_t] = []
    for _ in 0..<300 {
      if
        let text = try? String(contentsOf: pidFile, encoding: .utf8),
        case let parsed = text.split(whereSeparator: \.isWhitespace).compactMap({ pid_t($0) }),
        parsed.count == 2
      {
        pids = parsed
        break
      }
      try await Task.sleep(for: .milliseconds(10))
    }
    try #require(pids.count == 2, "the fixture helper never reported its pids")
    for pid in pids {
      try #require(kill(pid, 0) == 0, "precondition: pid \(pid) must be alive before the quit")
    }

    await engine.shutDown()

    // Polled, not asserted on the first read: a killed grandchild is
    // reparented to launchd and stays a zombie — which `kill(pid, 0)` still
    // reports as alive — until launchd gets round to reaping it.
    for pid in pids {
      var gone = false
      for _ in 0..<200 {
        if kill(pid, 0) != 0 { gone = true; break }
        try await Task.sleep(for: .milliseconds(10))
      }
      #expect(gone, "pid \(pid) outlived the app; it is an orphan")
    }
  }
}
