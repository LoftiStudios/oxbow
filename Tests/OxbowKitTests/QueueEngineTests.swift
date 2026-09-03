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


  /// `start(runsWork: false)` publishes the store exactly as written.
  ///
  /// This is what `scripts/screenshots.sh` relies on: it launches the real app
  /// against a fabricated queue so a published screenshot need not contain a
  /// real streamer's name, and both halves of a normal start would ruin that.
  /// `tick()` would try to download the invented video ids and settle every
  /// step as failed, and `Reconciler` would first demote the `running` step —
  /// correctly, since a running step on disk means the app died mid-step.
  /// Between them a fixture could only ever depict a finished queue, which
  /// shows none of the per-step progress the interface exists to present.
  ///
  /// So the property under test is that a `running` step survives the load,
  /// which is precisely what a normal start is supposed to prevent.
  @Test func loadingWithoutRunningWorkPublishesTheStoreVerbatim() async throws {
    let root = makeRoot()
    defer { cleanUp(root) }

    let step = Step(
      id: StepID(rawValue: UUID()),
      kind: .downloadVideo(VideoRequest(
        videoID: "invented", quality: "",
        destination: root.appending(path: "out.mp4"))),
      status: .running,
      progress: StepProgress(phase: "Downloading", fraction: 0.35),
      dependsOn: [])
    let job = Job(
      id: JobID(rawValue: UUID()),
      created: Date(timeIntervalSinceReferenceDate: 810_000_000),
      title: "CrashOverride - a fabricated row",
      steps: [step])
    try QueueStore(fileURL: storeURL(for: root)).save([job])

    let engine = QueueEngine(configuration: makeConfiguration(
      root: root,
      makeProcess: { FakeHelper(.failsWithoutArtifact(stderr: "must never run")) }))

    try await engine.start(runsWork: false)

    let loaded = try #require(await engine.currentJobs.first)
    #expect(loaded.title == "CrashOverride - a fabricated row")
    let only = try #require(loaded.steps.first)
    #expect(only.status == .running, "a normal start would have demoted this")
    #expect(only.progress.fraction == 0.35)
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
  /// render frame batch. Writing them all to the log would bury the handful
  /// of lines that actually say what a step was doing when it stopped, so
  /// only a periodic heartbeat (`QueueEngine.heartbeat`) reaches the log —
  /// and only once a step has run long enough for one to be due. This step
  /// reports exactly one status line before failing, well under
  /// `heartbeatInterval`, so no heartbeat fires at all.
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

  // MARK: - Delivering into an occupied destination

  /// Nobody was warned, so nothing may be destroyed. A file that appeared at
  /// the destination while a long download was running is left exactly as it
  /// was, and the finished download lands beside it under a stepped name —
  /// which is the name the step reports as delivered, so Show in Finder and
  /// Get Info point at the file that actually exists.
  @Test func deliversBesideAFileTheUserWasNeverWarnedAbout() async throws {
    let (engine, root) = makeEngine(.succeeds)
    let folder = URL(filePath: NSTemporaryDirectory())
      .appending(path: "oxbow-collision-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer {
      cleanUp(root)
      try? FileManager.default.removeItem(at: folder)
    }
    let destination = folder.appending(path: "out.mp4")
    try "an older download".write(to: destination, atomically: true, encoding: .utf8)

    try await engine.start()
    await engine.enqueue(
      JobTemplate(media: .video(VideoRequest(
        videoID: "1", quality: "", destination: destination))),
      title: "t")
    try await settle(engine)

    #expect(try String(contentsOf: destination, encoding: .utf8) == "an older download")
    let job = try #require(await engine.currentJobs.first)
    #expect(job.deliveredFiles == [folder.appending(path: "out (2).mp4")])
    await engine.flush()
  }

  /// The intake sheet showed the warning and the user chose Replace, so
  /// replacing is what they asked for. Stepping the name aside here would
  /// quietly overrule them and leave the stale file as the one they find.
  @Test func replacesTheExistingFileWhenTheUserAgreedToIt() async throws {
    let (engine, root) = makeEngine(.succeeds)
    let folder = URL(filePath: NSTemporaryDirectory())
      .appending(path: "oxbow-collision-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer {
      cleanUp(root)
      try? FileManager.default.removeItem(at: folder)
    }
    let destination = folder.appending(path: "out.mp4")
    try "an older download".write(to: destination, atomically: true, encoding: .utf8)

    try await engine.start()
    await engine.enqueue(
      JobTemplate(
        media: .video(VideoRequest(videoID: "1", quality: "", destination: destination)),
        replacesExistingFile: true),
      title: "t")
    try await settle(engine)

    let job = try #require(await engine.currentJobs.first)
    #expect(job.deliveredFiles == [destination])
    #expect(try String(contentsOf: destination, encoding: .utf8) != "an older download")
    #expect(!FileManager.default.fileExists(atPath: folder.appending(path: "out (2).mp4").path))
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

  /// A composite that exits 0 having produced no frames must fail, not
  /// succeed.
  ///
  /// This is the guard the chat-seek bug went undetected behind. FFmpeg's
  /// exit code says nothing here — the engine already knows that, which is
  /// why `isUsableArtifact` exists — but "exists and is non-empty" is not
  /// enough for a piece: a filter graph that yields nothing still writes
  /// `ftyp` and `moov`, so the file is neither missing nor zero-length and
  /// every existence check reads it as finished. `.assemble` would then
  /// concatenate it as an empty segment and deliver a file truncated at the
  /// seam, with no error anywhere.
  ///
  /// The piece is the one artifact in the pipeline whose emptiness is
  /// readable without decoding — `trun` declares each fragment's sample
  /// count — so this costs a box walk, not a subprocess.
  @Test func aCompositeThatProducesNoFramesFailsRatherThanDeliveringATruncatedFile() async throws {
    let helper = FakeHelper(.writesAFramelessPiece)
    let (engine, root) = makeEngine { helper }
    defer { cleanUp(root) }

    let template = JobTemplate(
      media: .video(VideoRequest(videoID: "v", quality: "1080p60")),
      render: RenderRequest(),
      composite: CompositeRequest(
        framerate: 60,
        duration: .seconds(60),
        destination: root.appending(path: "out.mp4")))

    try await engine.start()
    await engine.enqueue(template, title: "t")
    try await settle(engine)

    let steps = await engine.currentJobs[0].steps
    let composite = try #require(steps.first { if case .composite = $0.kind { true } else { false } })

    guard case .failed(let failure) = composite.status else {
      Issue.record("expected a frameless piece to fail the composite, got \(composite.status)")
      return
    }
    #expect(failure.kind == .noArtifact)

    // And the delivery never happens: assemble must not have run on it.
    let assemble = try #require(steps.first { if case .assemble = $0.kind { true } else { false } })
    #expect(assemble.status == .blocked)

    await engine.flush()
  }

  /// The "one file out" promise the whole feature rests on: a composite job's
  /// video, chat render, AND composite are all intermediates shaped exactly
  /// like real intake output (`destination: nil`, or in the composite's case
  /// a destination `move` deliberately ignores) and must never reach the
  /// user's chosen folder — only the assemble step, which joins the
  /// composite's pieces, is delivered.
  @Test func aCompositeJobDeliversExactlyOneFile() async throws {
    let (engine, root) = makeEngine(.succeeds)
    defer { cleanUp(root) }

    let destination = root.appending(path: "out.mp4")
    let template = JobTemplate(
      media: .video(VideoRequest(videoID: "v", quality: "1080p60")),
      render: RenderRequest(),
      composite: CompositeRequest(
        framerate: 60,
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
    // dropped in the same breath. The composite's own output is a piece in
    // the retention area, not the delivered file — `Workspace.contains`
    // deliberately excludes that area (see its doc comment), so the done
    // job's workspace sweep never touches it directly. What actually removes
    // the bytes is delivery-time retention cleanup (docs/design/resume.md
    // §8): a delivered job has nothing left to resume, so `removeJobWorkspace`
    // drops the whole retained directory — and, in the same actor turn, nils
    // the composite step's claim on it, so nothing is left pointing at a
    // piece that no longer exists (`Reconciler` short-circuits for a `.done`
    // job, so there is no later chance to notice a stale one).
    let workspace = Workspace(root: root)
    for step in job.steps {
      switch step.kind {
      case .assemble:
        #expect(step.artifact == destination)
      case .composite, .downloadVideo, .downloadClip, .downloadChat, .renderChat:
        #expect(step.artifact == nil, "an intermediate must not be claimed")
      }
    }

    #expect(FileManager.default.fileExists(atPath: destination.path))
    #expect(!FileManager.default.fileExists(
      atPath: workspace.resumeDirectory(job.id).path),
      "a delivered job's retained pieces have no further use")

    // Nothing else reached disk under root except the assembled file — the
    // video, render, and retained composite piece were all cleared once the
    // job delivered.
    let enumerator = FileManager.default.enumerator(atPath: root.path)
    let delivered = (enumerator?.allObjects as? [String] ?? []).filter { $0.hasSuffix(".mp4") }
    #expect(Set(delivered) == ["out.mp4"])

    await engine.flush()
  }

  /// The composite step's Finder-reveal item, rule 2: once a job has fully
  /// delivered, `removeJobWorkspace` has already deleted its retention area
  /// (verified just above), so pointing at it would be a dead directory. The
  /// item must fall back to what the job actually produced — the `.assemble`
  /// step's own artifact — rather than leaving the user staring at nothing.
  @Test func revealTargetPointsAtTheDeliveredFileOnceRetentionIsGone() async throws {
    let (engine, root) = makeEngine(.succeeds)
    defer { cleanUp(root) }

    let destination = root.appending(path: "out.mp4")
    let template = JobTemplate(
      media: .video(VideoRequest(videoID: "v", quality: "1080p60")),
      render: RenderRequest(),
      composite: CompositeRequest(
        framerate: 60,
        duration: .seconds(60),
        destination: destination))

    try await engine.start()
    await engine.enqueue(template, title: "t")
    try await settle(engine)

    let job = try #require(await engine.currentJobs.first)
    #expect(await engine.revealTarget(forJob: job.id) == .delivered(destination))

    await engine.flush()
  }

  /// The composite step's Finder-reveal item, rule 2 continued: pinned to the
  /// `.assemble` step specifically, never `job.deliveredFiles.first`. Those
  /// two coincide today only because the intake gives chat, video, and render
  /// steps `destination: nil` on a composite job — nothing in `JobTemplate`
  /// stops a caller from setting one anyway, and step order puts chat ahead
  /// of assemble. Without the pin, this would reveal the chat JSON instead of
  /// the finished video the moment both deliver — exactly the drift the
  /// review that produced this test called out.
  @Test func revealTargetPrefersTheAssembleStepOverAnEarlierDeliveringStep() async throws {
    let (engine, root) = makeEngine(.succeeds)
    defer { cleanUp(root) }

    let chatDestination = root.appending(path: "out.json")
    let videoDestination = root.appending(path: "out.mp4")
    let template = JobTemplate(
      media: .video(VideoRequest(videoID: "v", quality: "1080p60")),
      chat: ChatRequest(videoID: "v", format: .json, destination: chatDestination),
      render: RenderRequest(),
      composite: CompositeRequest(
        framerate: 60,
        duration: .seconds(60),
        destination: videoDestination))

    try await engine.start()
    await engine.enqueue(template, title: "t")
    try await settle(engine)

    let job = try #require(await engine.currentJobs.first)
    // Both the chat step and the assemble step delivered — chat earlier in
    // step order — which is what makes this pin down "follows assemble
    // specifically" rather than "follows whichever delivering step is first".
    #expect(job.deliveredFiles.count == 2)
    #expect(await engine.revealTarget(forJob: job.id) == .delivered(videoDestination))

    await engine.flush()
  }

  /// The composite step's Finder-reveal item, rule 2's other half: rule 1
  /// checks the retention directory still exists before trusting it, and the
  /// delivered branch owes its own file the same check. Moved or deleted
  /// after delivery, `assemble.artifact` still names it — the exact defect
  /// `e61278f` fixed on the retention branch, reproduced here on the
  /// delivered one.
  @Test func revealTargetIsNilWhenTheDeliveredFileNoLongerExists() async throws {
    let (engine, root) = makeEngine(.succeeds)
    defer { cleanUp(root) }

    let destination = root.appending(path: "out.mp4")
    let template = JobTemplate(
      media: .video(VideoRequest(videoID: "v", quality: "1080p60")),
      render: RenderRequest(),
      composite: CompositeRequest(
        framerate: 60,
        duration: .seconds(60),
        destination: destination))

    try await engine.start()
    await engine.enqueue(template, title: "t")
    try await settle(engine)

    let job = try #require(await engine.currentJobs.first)
    #expect(await engine.revealTarget(forJob: job.id) == .delivered(destination))

    try FileManager.default.removeItem(at: destination)

    #expect(
      await engine.revealTarget(forJob: job.id) == nil,
      "an enabled item pointing at a moved-or-deleted file is the bug this exists to avoid")

    await engine.flush()
  }

  /// `removeJobWorkspace`'s `.done` branch nils a step's claim on any
  /// artifact `Workspace.contains` recognises, then separately deletes the
  /// whole retained directory. The composite step's own artifact lives
  /// *inside* that retained directory, which `contains` deliberately does not
  /// recognise (see its doc comment) — so without an explicit fix, the nilling
  /// loop skips it and the deletion removes the file out from under a claim
  /// that survives. That dangling reference is user-visible:
  /// `JobInfo.deliveredFiles` and "Show in Finder" (`QueueActions.swift`)
  /// both read a step's `artifact`, so a delivered job would list, and offer
  /// to reveal, a `piece-0.mp4` this same delivery just deleted.
  @Test func aDeliveredCompositeJobDoesNotClaimItsRemovedPiece() async throws {
    let (engine, root) = makeEngine(.succeeds)
    defer { cleanUp(root) }

    let template = JobTemplate(
      media: .video(VideoRequest(videoID: "v", quality: "1080p60")),
      render: RenderRequest(),
      composite: CompositeRequest(
        framerate: 60, duration: .seconds(60),
        destination: root.appending(path: "out.mp4")))

    try await engine.start()
    await engine.enqueue(template, title: "t")
    try await settle(engine)

    let job = try #require(await engine.currentJobs.first)
    #expect(job.status == .done, "precondition")
    let composite = try #require(job.steps.first {
      if case .composite = $0.kind { return true }
      return false
    })

    #expect(composite.artifact == nil,
            "the composite step must not claim a piece that delivery just removed")

    await engine.flush()
  }

  /// The failure mode `move`'s `.composite` case exists to prevent: composite
  /// and assemble carry the *same* destination (`JobTemplate` builds the
  /// `AssembleRequest` from `CompositeRequest.destination`), so if `move`
  /// ever let `.composite` deliver again, this would pass by coincidence —
  /// the file would land at the right path just one step early, with fewer
  /// pieces joined than a resumed job actually produced. Caught mid-flight,
  /// with assemble deliberately held `.running` so the moment the composite
  /// alone could have delivered is directly observable: the destination must
  /// not exist while composite is `.done` and assemble has not finished.
  @Test func aCompositeStepNeverDeliversToItsOwnDestination() async throws {
    let sequenced = SequencedBehaviours(
      [.succeeds, .succeeds, .succeeds, .succeeds, .hangsUntilCancelled])
    let (engine, root) = makeEngine { FakeHelper(sequenced.next()) }
    defer { cleanUp(root) }

    let destination = root.appending(path: "out.mp4")
    try await engine.start()
    await engine.enqueue(
      JobTemplate(
        media: .video(VideoRequest(videoID: "v", quality: "1080p60")),
        render: RenderRequest(),
        composite: CompositeRequest(
          framerate: 60, duration: .seconds(60),
          destination: destination)),
      title: "t")

    // Step order is chat, render, video, composite, assemble (`JobTemplate`'s
    // load-bearing append order). Wait for the composite to finish and the
    // assemble step — which shares the composite's destination — to be
    // genuinely in flight, held there by the fake's last behaviour.
    for _ in 0..<200 {
      let steps = await engine.currentJobs.first?.steps
      if steps?[3].status == .done, steps?[4].status == .running {
        break
      }
      try await Task.sleep(for: .milliseconds(10))
    }
    let steps = try #require(await engine.currentJobs.first?.steps)
    #expect(steps[3].status == .done, "precondition: composite must have finished")
    #expect(steps[4].status == .running, "precondition: assemble must be genuinely in flight")

    #expect(!FileManager.default.fileExists(atPath: destination.path),
            "the composite must not have delivered its own destination")

    let jobID = try #require(await engine.currentJobs.first?.id)
    await engine.cancel(job: jobID)
    try await settle(engine)
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

  /// A stubborn file inside a step's own working directory must not vanish
  /// into the same silence a whole-job teardown failure used to: found on a
  /// real machine as an 8.66 GB video that survived its job's teardown with
  /// nothing anywhere recording that the removal had failed.
  ///
  /// `chflags`'s user-immutable flag is used to force a genuine
  /// `FileManager.removeItem` failure — unlike an open file handle, which
  /// does not stop `unlink` on APFS, or a read-only file, which is still
  /// removable by the owner of a writable directory. `uchg` is the one
  /// portable way to make deletion itself fail.
  ///
  /// `removeStep` only ever touches a step's own working directory, never
  /// `logs/` — so unlike a job-level failure (see
  /// `aJobTeardownFailureIsRecordedInTheWorkspaceLevelLog` below), this one
  /// has an obvious, still-standing home: the step's own `StepLog`.
  @Test func aStepTeardownFailureIsRecordedInThatStepsOwnLog() async throws {
    let (engine, root) = makeEngine(.hangsUntilCancelled)
    defer { cleanUp(root) }
    let workspace = Workspace(root: root)

    try await engine.start()
    await engine.enqueue(
      JobTemplate(chat: ChatRequest(videoID: "2844548319", format: .json)), title: "test")

    // `enqueue` runs `tick()` — and so `makeContext`'s `prepareStep` — to
    // completion synchronously before returning, so the step's working
    // directory already exists here; no polling needed.
    let jobID = try #require(await engine.currentJobs.first?.id)
    let stepID = try #require(await engine.currentJobs.first?.steps.first?.id)

    let stuck = workspace.stepDirectory(job: jobID, step: stepID).appending(path: "stuck.tmp")
    FileManager.default.createFile(atPath: stuck.path, contents: Data("x".utf8))
    try #require(
      chflags(stuck.path, UInt32(UF_IMMUTABLE)) == 0,
      "precondition: chflags must succeed to force the failure this test is after")
    defer { chflags(stuck.path, 0) }

    await engine.cancel(step: stepID)
    try await settle(engine)

    // The teardown failure is written by a fire-and-forget `Task` (see
    // `recordStepTeardownFailure`), so it may still be in flight the moment
    // `isIdle` goes true — poll rather than reading the log exactly once.
    let logFile = workspace.logFile(job: jobID, step: stepID)
    var contents = ""
    for _ in 0..<80 {
      contents = (try? String(contentsOf: logFile, encoding: .utf8)) ?? ""
      if contents.contains("stuck.tmp") { break }
      try await Task.sleep(for: .milliseconds(25))
    }

    #expect(contents.contains("teardown"), "step log should record the teardown failure; log was: \(contents)")
    #expect(
      contents.contains("stuck.tmp"),
      "step log should name the file that survived removal; log was: \(contents)")
    #expect(
      FileManager.default.fileExists(atPath: stuck.path),
      "the file the failure names must actually still be there")

    await engine.flush()
  }

  /// The job-level counterpart of the test above. `removeJob` deletes a
  /// job's own `logs/` directory as part of what it tears down, so a
  /// job-level failure has nowhere per-job to land — this is what confirms
  /// it lands in `Workspace.teardownFailureLog` instead, and that the file
  /// naming the failure survives it.
  @Test func aJobTeardownFailureIsRecordedInTheWorkspaceLevelLog() async throws {
    let (engine, root) = makeEngine(.hangsUntilCancelled)
    defer { cleanUp(root) }
    let workspace = Workspace(root: root)

    try await engine.start()
    await engine.enqueue(
      JobTemplate(chat: ChatRequest(videoID: "2844548319", format: .json)), title: "test")

    let jobID = try #require(await engine.currentJobs.first?.id)

    // A stray file directly in the job's own directory — a sibling of
    // `artifacts/` and `logs/` — so its removal failing aborts nothing
    // upstream of it and this test is purely about where the failure is
    // *reported*, not whether siblings survive (that is `WorkspaceTests`'
    // job, at the `Workspace` level where it can be asserted without an
    // engine's timing in the way).
    let stuck = workspace.jobDirectory(jobID).appending(path: "stuck.tmp")
    FileManager.default.createFile(atPath: stuck.path, contents: Data("x".utf8))
    try #require(
      chflags(stuck.path, UInt32(UF_IMMUTABLE)) == 0,
      "precondition: chflags must succeed to force the failure this test is after")
    defer { chflags(stuck.path, 0) }

    await engine.cancel(job: jobID)
    try await settle(engine)

    let logFile = workspace.teardownFailureLog
    var contents = ""
    for _ in 0..<80 {
      contents = (try? String(contentsOf: logFile, encoding: .utf8)) ?? ""
      if contents.contains("stuck.tmp") { break }
      try await Task.sleep(for: .milliseconds(25))
    }

    #expect(
      contents.contains(jobID.rawValue.uuidString),
      "the workspace-level log should name the job it happened to; log was: \(contents)")
    #expect(
      contents.contains("stuck.tmp"),
      "the workspace-level log should name the file that survived removal; log was: \(contents)")
    #expect(
      FileManager.default.fileExists(atPath: stuck.path),
      "the file the failure names must actually still be there")

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
          framerate: 60, duration: .seconds(60),
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

  // MARK: - Resume

  /// Everything the resume tests need: an engine wired to a real workspace,
  /// and a job whose only step is a composite. `dependsOn` is left empty —
  /// `makeContext`'s wiring guard only checks that inputs and `dependsOn`
  /// agree in count, and these tests are aimed at the resume machinery, not
  /// at wiring a full multi-step job.
  private struct ResumeHarness {
    let engine: QueueEngine
    let workspace: Workspace
    let job: Job
    let store: QueueStore
    private let cleanup: () -> Void

    init(
      engine: QueueEngine, workspace: Workspace, job: Job, store: QueueStore,
      cleanup: @escaping () -> Void)
    {
      self.engine = engine
      self.workspace = workspace
      self.job = job
      self.store = store
      self.cleanup = cleanup
    }

    /// Exercises `QueueEngine.makeContext` directly for the composite step —
    /// the same call `launch(_:)` makes, without actually running a job.
    func engineContext(forCompositeOf job: Job) throws -> StepContext {
      try engine.makeContext(job: job, step: job.steps[0])
    }

    /// A piece already on disk, built from the same box layouts
    /// `FragmentIndexTests` uses — a single fragment declaring `frames`
    /// samples is all `resumePoint` ever reads.
    func writePiece(index: Int, frames: Int) throws {
      try FileManager.default.createDirectory(
        at: workspace.resumeDirectory(job.id), withIntermediateDirectories: true)
      let data = FragmentBuilder.fragmentedFile([UInt32(frames)])
      try data.write(
        to: workspace.resumeDirectory(job.id).appending(path: "piece-\(index).mp4"))
    }

    /// What piece 0 was (supposedly) built from — written here rather than
    /// produced by a real first attempt, so a test can dial in a mismatch
    /// directly instead of running two composites to provoke one.
    func writeFingerprint(byteCount: Int, duration: Duration) throws {
      try FileManager.default.createDirectory(
        at: workspace.resumeDirectory(job.id), withIntermediateDirectories: true)
      try SourceFingerprint(byteCount: byteCount, duration: duration)
        .write(to: workspace.resumeDirectory(job.id).appending(path: "source.json"))
    }

    /// A video file of an exact size, standing in for a re-downloaded source —
    /// written directly rather than run through a helper, so a test can dial
    /// in the precise byte count `SourceFingerprint` compares against. The
    /// return value only matters to callers that need to assert on the path
    /// afterward — `aChangedSourceRefusesToResume` only needs the file on
    /// disk, not the URL back.
    @discardableResult
    func writeVideoArtifact(byteCount: Int) throws -> URL {
      let url = try workspace.prepareArtifacts(job: job.id).appending(path: "video.mp4")
      try Data(count: byteCount).write(to: url)
      return url
    }

    /// The chat render's stand-in, same reasoning as `writeVideoArtifact`.
    @discardableResult
    func writeRenderArtifact(byteCount: Int) throws -> URL {
      let url = try workspace.prepareArtifacts(job: job.id).appending(path: "render.mp4")
      try Data(count: byteCount).write(to: url)
      return url
    }

    /// A finalised sidecar: `ftyp` + `mdat` + a complete trailing `moov` — the
    /// layout a first attempt's `-c:a copy` produces when it runs to
    /// completion. Same box-building helper `FragmentIndexTests` uses.
    func writeUsableSidecar() throws {
      try FileManager.default.createDirectory(
        at: workspace.resumeDirectory(job.id), withIntermediateDirectories: true)
      var data = FragmentBuilder.box("ftyp", Data(repeating: 0, count: 8))
      data.append(FragmentBuilder.box("mdat", Data(repeating: 0xAB, count: 32)))
      data.append(FragmentBuilder.box("moov", Data(repeating: 0, count: 16)))
      try data.write(to: workspace.resumeDirectory(job.id).appending(path: "audio.m4a"))
    }

    /// What a genuine `SIGKILL` mid-write leaves behind: `ftyp` + `mdat`, no
    /// `moov` at all, because the encoder writes it last.
    func writeCorruptSidecar() throws {
      try FileManager.default.createDirectory(
        at: workspace.resumeDirectory(job.id), withIntermediateDirectories: true)
      var data = FragmentBuilder.box("ftyp", Data(repeating: 0, count: 8))
      data.append(FragmentBuilder.box("mdat", Data(repeating: 0xAB, count: 32)))
      try data.write(to: workspace.resumeDirectory(job.id).appending(path: "audio.m4a"))
    }

    /// Exercises the composite branch of `makeContext` directly, wired to a
    /// video dependency so the source-fingerprint check has something to
    /// compare — and translates a thrown `SourceChangedError` the way
    /// `launch(_:)` does, since that translation is what a caller actually
    /// sees.
    func runComposite() async -> StepOutcome {
      let videoStep = Step(
        id: StepID(rawValue: UUID()),
        kind: .downloadVideo(VideoRequest(videoID: "v", quality: "best")),
        status: .done,
        artifact: workspace.artifactsDirectory(job.id).appending(path: "video.mp4"))
      let compositeStep = Step(
        id: StepID(rawValue: UUID()),
        kind: .composite(CompositeRequest(
          framerate: 30, duration: .seconds(547),
          destination: workspace.root.appending(path: "out.mp4"))),
        dependsOn: [videoStep.id])
      let wired = Job(id: job.id, created: job.created, title: job.title,
                       steps: [videoStep, compositeStep])

      do {
        let context = try engine.makeContext(job: wired, step: compositeStep)
        return .succeeded(artifact: context.outputFile)
      } catch let error as SourceChangedError {
        return .failed(StepFailure(
          kind: .noArtifact,
          summary: error.reason ?? "The source changed since this download started. Start it again."))
      } catch {
        return .failed(StepFailure(kind: .launchFailed("\(error)"), summary: "\(error)"))
      }
    }

    /// Exercises the assemble branch of `makeContext` directly, wired to a
    /// video and a render dependency so there is something for it to drop.
    /// The deletion is a plain filesystem side effect of building the
    /// context, so there is nothing further to run.
    func runAssemble() async {
      let videoStep = Step(
        id: StepID(rawValue: UUID()),
        kind: .downloadVideo(VideoRequest(videoID: "v", quality: "best")),
        status: .done,
        artifact: workspace.artifactsDirectory(job.id).appending(path: "video.mp4"))
      let renderStep = Step(
        id: StepID(rawValue: UUID()),
        kind: .renderChat(RenderRequest()),
        status: .done,
        artifact: workspace.artifactsDirectory(job.id).appending(path: "render.mp4"))
      let compositeStep = Step(
        id: StepID(rawValue: UUID()),
        kind: .composite(CompositeRequest(
          framerate: 30, duration: .seconds(60),
          destination: workspace.root.appending(path: "out.mp4"))),
        status: .done,
        dependsOn: [videoStep.id, renderStep.id],
        // Never read by the assemble branch — it hardcodes the sidecar path
        // instead — but `makeContext`'s wiring guard still counts it, so a
        // nil here would misreport this as a wiring bug rather than
        // exercising the deletion this test is actually after.
        artifact: workspace.resumeDirectory(job.id).appending(path: "piece-0.mp4"))
      let assembleStep = Step(
        id: StepID(rawValue: UUID()),
        kind: .assemble(AssembleRequest(destination: workspace.root.appending(path: "out.mp4"))),
        dependsOn: [compositeStep.id])
      let wired = Job(id: job.id, created: job.created, title: job.title,
                       steps: [videoStep, renderStep, compositeStep, assembleStep])

      _ = try? engine.makeContext(job: wired, step: assembleStep)
    }

    /// Runs `job` to real completion through the engine's own pipeline,
    /// rather than through `makeContext` directly — clearing the resume area
    /// on delivery is `QueueEngine.removeJobWorkspace`'s doing, and that only
    /// fires from inside the actor once the job's own steps are genuinely
    /// `.done`.
    func completeJobSuccessfully() async {
      try? store.save([job])
      try? await engine.start()
      for _ in 0..<200 {
        if await engine.isIdle { return }
        try? await Task.sleep(for: .milliseconds(25))
      }
    }

    func tearDown() {
      cleanup()
    }
  }

  private func makeHarness() throws -> ResumeHarness {
    let root = makeRoot()
    let workspace = Workspace(root: root)
    let engine = QueueEngine(configuration: makeConfiguration(root: root) { FakeHelper(.succeeds) })

    // 30fps so a piece's frame count converts to seconds by simple division —
    // see aSecondAttemptResumesAfterTheSurvivingFrames.
    let job = Job(
      id: JobID(rawValue: UUID()),
      created: Date(),
      title: "resume",
      steps: [Step(
        id: StepID(rawValue: UUID()),
        kind: .composite(CompositeRequest(
          framerate: 30, duration: .seconds(60),
          destination: root.appending(path: "out.mp4"))))])

    return ResumeHarness(
      engine: engine, workspace: workspace, job: job,
      store: QueueStore(fileURL: storeURL(for: root))
    ) { self.cleanUp(root) }
  }

  /// A first attempt writes piece-0 into the retention area, not the workspace
  /// — the workspace is swept at launch and the whole point is surviving that.
  @Test func aCompositeWritesItsFirstPieceIntoTheResumeArea() async throws {
    let harness = try makeHarness()
    defer { harness.tearDown() }

    let context = try harness.engineContext(forCompositeOf: harness.job)

    #expect(context.outputFile.lastPathComponent == "piece-0.mp4")
    // `.path`, not `==`, on the URLs themselves: `deletingLastPathComponent()`
    // always returns a directory-flavoured URL (trailing slash), which never
    // compares equal via `==` to the file-flavoured URL `resumeDirectory`
    // returns even for the identical path — the same reason `WorkspaceTests`
    // compares `.path` rather than the URLs directly.
    #expect(context.outputFile.deletingLastPathComponent().path
      == harness.workspace.resumeDirectory(harness.job.id).path)
    #expect(context.resumeFrom == nil)
  }

  /// With a piece already on disk, the next attempt continues rather than
  /// restarting: a new piece, and a seek derived from the frames that survived.
  @Test func aSecondAttemptResumesAfterTheSurvivingFrames() async throws {
    let harness = try makeHarness()
    defer { harness.tearDown() }
    // 90 frames at 30 fps == 3.0 seconds.
    try harness.writePiece(index: 0, frames: 90)

    let context = try harness.engineContext(forCompositeOf: harness.job)

    #expect(context.outputFile.lastPathComponent == "piece-1.mp4")
    #expect(context.resumeFrom == .seconds(3))
  }

  /// Past the cap, a retry starts over: a job that has failed this many times
  /// is reporting something resuming will not fix. resume.md §7.
  @Test func theFifthAttemptStartsOver() async throws {
    let harness = try makeHarness()
    defer { harness.tearDown() }
    for index in 0 ..< 4 { try harness.writePiece(index: index, frames: 30) }

    let context = try harness.engineContext(forCompositeOf: harness.job)

    #expect(context.outputFile.lastPathComponent == "piece-0.mp4")
    #expect(context.resumeFrom == nil)
    // The cap reset drops the whole retained directory (`removeResumable`)
    // and `prepareResume` recreates it empty right after — so this pins that
    // it comes back genuinely empty, not merely present. If `removeResumable`
    // ever silently failed, `piece-1` through `piece-3` would survive here,
    // the fresh run would overwrite only `piece-0`, and assemble would splice
    // three stale pieces onto one fresh one — a silently wrong video.
    let contents = try FileManager.default.contentsOfDirectory(
      atPath: harness.workspace.resumeDirectory(harness.job.id).path)
    #expect(contents.isEmpty)
  }

  /// A piece that reached only `ftyp`+`moov` before the crash — killed before
  /// a single fragment finished — has nothing to resume from and must not be
  /// treated as a real attempt: left in place it would burn a slot against
  /// the piece cap and hand `.assemble` an empty segment in `pieces.txt`.
  /// resume.md §7.
  @Test func aZeroFramePieceIsDiscardedRatherThanCounted() async throws {
    let harness = try makeHarness()
    defer { harness.tearDown() }
    try harness.writePiece(index: 0, frames: 90)
    try harness.writePiece(index: 1, frames: 0)

    let context = try harness.engineContext(forCompositeOf: harness.job)

    // The zero-frame piece must not have claimed an index of its own — the
    // next attempt reuses it rather than continuing past it.
    #expect(context.outputFile.lastPathComponent == "piece-1.mp4")
    // 90 frames at 30 fps == 3.0s, from the real piece alone.
    #expect(context.resumeFrom == .seconds(3))
    #expect(!FileManager.default.fileExists(
      atPath: harness.workspace.resumeDirectory(harness.job.id).appending(path: "piece-1.mp4").path),
      "a zero-frame piece must be removed outright, not left to reach .assemble's pieces.txt")
  }

  /// No sidecar on disk at all — a genuine first attempt — must not be
  /// reported as usable. `hasUsableSidecar` defaults to `false` in
  /// `StepContext`, but this pins that `QueueEngine` actually computes it
  /// rather than relying on the default surviving by accident.
  @Test func aFirstAttemptHasNoUsableSidecar() async throws {
    let harness = try makeHarness()
    defer { harness.tearDown() }

    let context = try harness.engineContext(forCompositeOf: harness.job)

    #expect(!context.hasUsableSidecar)
  }

  /// The bug this branch fixes: a sidecar surviving from an earlier attempt
  /// must be checked for a complete `moov`, not just "on disk" — a
  /// `SIGKILL` mid-write leaves a non-empty file that is not usable.
  @Test func aRetryWithACorruptSidecarReportsItAsUnusable() async throws {
    let harness = try makeHarness()
    defer { harness.tearDown() }
    try harness.writePiece(index: 0, frames: 90)
    try harness.writeCorruptSidecar()

    let context = try harness.engineContext(forCompositeOf: harness.job)

    #expect(!context.hasUsableSidecar)
  }

  /// A sidecar that finished writing normally (the graceful-`SIGTERM` case,
  /// or a resume that already repaired it) must be reported usable, so
  /// `ArgumentBuilder` leaves it alone rather than needlessly re-copying it.
  @Test func aRetryWithAnIntactSidecarReportsItAsUsable() async throws {
    let harness = try makeHarness()
    defer { harness.tearDown() }
    try harness.writePiece(index: 0, frames: 90)
    try harness.writeUsableSidecar()

    let context = try harness.engineContext(forCompositeOf: harness.job)

    #expect(context.hasUsableSidecar)
  }

  /// A changed source must refuse rather than splice two different videos
  /// together. resume.md §7.
  @Test func aChangedSourceRefusesToResume() async throws {
    let harness = try makeHarness()
    defer { harness.tearDown() }
    try harness.writePiece(index: 0, frames: 30)
    try harness.writeFingerprint(byteCount: 1000, duration: .seconds(547))
    try harness.writeVideoArtifact(byteCount: 2000)

    let outcome = await harness.runComposite()

    guard case .failed(let failure) = outcome else {
      Issue.record("expected refusal, got \(outcome)")
      return
    }
    #expect(failure.summary.contains("source changed"))
  }

  /// The fail-open twin of `aChangedSourceRefusesToResume`: no `source.json`
  /// at all, as if the first attempt's own `try?` write had failed — a full
  /// disk is the likeliest reason a composite failed in the first place, and
  /// also the likeliest reason the fingerprint write failed alongside it. A
  /// resume that cannot verify its source must refuse the same as one that
  /// verifies and finds a mismatch, not silently treat "unreadable" as
  /// "matches". resume.md §7.
  @Test func aMissingFingerprintRefusesToResume() async throws {
    let harness = try makeHarness()
    defer { harness.tearDown() }
    try harness.writePiece(index: 0, frames: 30)
    // Deliberately no `writeFingerprint` call — `source.json` is absent.
    try harness.writeVideoArtifact(byteCount: 2000)

    let outcome = await harness.runComposite()

    guard case .failed(let failure) = outcome else {
      Issue.record("expected refusal, got \(outcome)")
      return
    }
    // Not the mismatch wording: nothing was compared, so nothing "changed".
    #expect(!failure.summary.contains("source changed"))
    #expect(failure.summary.contains("could not be verified"))
  }

  /// Deleting the re-fetched inputs before assembling is what keeps the disk
  /// peak at ~58 GB rather than ~84 on a six-hour job. resume.md §5.
  @Test func assembleDropsTheRefetchedInputsFirst() async throws {
    let harness = try makeHarness()
    defer { harness.tearDown() }
    let video = try harness.writeVideoArtifact(byteCount: 10)
    let render = try harness.writeRenderArtifact(byteCount: 10)

    await harness.runAssemble()

    #expect(!FileManager.default.fileExists(atPath: video.path))
    #expect(!FileManager.default.fileExists(atPath: render.path))
  }

  /// Delivered means done: the retained bytes have no further use.
  @Test func aDeliveredJobClearsItsResumeArea() async throws {
    let harness = try makeHarness()
    defer { harness.tearDown() }
    try harness.writePiece(index: 0, frames: 30)

    await harness.completeJobSuccessfully()

    #expect(!FileManager.default.fileExists(
      atPath: harness.workspace.resumeDirectory(harness.job.id).path))
  }

  /// Dismissing a failed job is how a user reclaims the space, since retention
  /// is user-cleared for now. resume.md §8.
  @Test func removingAJobClearsItsResumeArea() async throws {
    let harness = try makeHarness()
    defer { harness.tearDown() }
    try harness.writePiece(index: 0, frames: 30)

    await harness.engine.remove(jobs: [harness.job.id])

    #expect(!FileManager.default.fileExists(
      atPath: harness.workspace.resumeDirectory(harness.job.id).path))
  }

  /// The number the failed row shows, so user-cleared retention stays honest.
  /// resume.md §8.
  @Test func retainedBytesAreReportedForAFailedJob() async throws {
    let harness = try makeHarness()
    defer { harness.tearDown() }
    try harness.writePiece(index: 0, frames: 30)

    let bytes = await harness.engine.retainedBytes(forJob: harness.job.id)

    #expect(bytes > 0)
  }

  @Test func aJobWithNoPiecesReportsNothingRetained() async throws {
    let harness = try makeHarness()
    defer { harness.tearDown() }

    #expect(await harness.engine.retainedBytes(forJob: harness.job.id) == 0)
  }

  /// What the composite step's Finder-reveal item points at
  /// (docs/design/fragmented-output.md §6): the retention directory, and the
  /// pieces inside it, in order — never anything under the job workspace.
  @Test func retainedFileURLsReportTheDirectoryAndItsPiecesInOrder() async throws {
    let harness = try makeHarness()
    defer { harness.tearDown() }
    try harness.writePiece(index: 1, frames: 30)
    try harness.writePiece(index: 0, frames: 30)

    let (directory, pieces) = await harness.engine.retainedFileURLs(forJob: harness.job.id)

    #expect(directory == harness.workspace.resumeDirectory(harness.job.id))
    #expect(pieces.map(\.lastPathComponent) == ["piece-0.mp4", "piece-1.mp4"])
  }

  /// The fallback the reveal action needs: a composite that has started but
  /// has not yet finished its first fragment still has a real, existing
  /// directory to point Finder at — `prepareResume` creates it the moment the
  /// step starts, before any `piece-*.mp4` exists.
  @Test func retainedFileURLsReportTheDirectoryEvenWithNoPiecesYet() async throws {
    let harness = try makeHarness()
    defer { harness.tearDown() }

    let (directory, pieces) = await harness.engine.retainedFileURLs(forJob: harness.job.id)

    #expect(directory == harness.workspace.resumeDirectory(harness.job.id))
    #expect(pieces.isEmpty)
  }

  /// The composite step's Finder-reveal item, rule 1: the retention area is
  /// still on disk, so it reveals what is actually there — the same answer
  /// `retainedFileURLs` already gives, wrapped so a caller does not have to
  /// separately decide whether that answer applies.
  @Test func revealTargetReportsRetainedPiecesWhileTheyAreOnDisk() async throws {
    let harness = try makeHarness()
    defer { harness.tearDown() }
    try harness.writePiece(index: 0, frames: 30)

    let target = await harness.engine.revealTarget(forJob: harness.job.id)

    // Built from the same call `revealTarget` itself makes, not from
    // `resumeDirectory` directly — `contentsOfDirectory` resolves `/var` to
    // `/private/var` on a real filesystem, and a hand-built expectation
    // would fail on that alone rather than on anything this test is
    // actually about.
    let (directory, pieces) = await harness.engine.retainedFileURLs(forJob: harness.job.id)
    #expect(target == .retained(directory: directory, pieces: pieces))
    #expect(pieces.map(\.lastPathComponent) == ["piece-0.mp4"])
  }

  /// Rule 3: a composite that has never started has neither a retention area
  /// nor anything delivered — there is genuinely nothing to reveal, and the
  /// item must disable rather than invent something to select.
  @Test func revealTargetIsNilBeforeTheCompositeHasEverStarted() async throws {
    let harness = try makeHarness()
    defer { harness.tearDown() }

    #expect(await harness.engine.revealTarget(forJob: harness.job.id) == nil)
  }

  /// The invariant resume.md §8 exists to protect, and the one no existing
  /// test pinned: cancellation is the one ending where retention is
  /// deliberately *kept*. `removeJobWorkspace`'s not-done branch has two
  /// early returns, and adding a stray `removeResumable` call to either
  /// would pass every other test in this file while quietly breaking this.
  @Test func cancellingAJobWithARetainedPieceKeepsIt() async throws {
    let root = makeRoot()
    let workspace = Workspace(root: root)
    let engine = QueueEngine(
      configuration: makeConfiguration(root: root) { FakeHelper(.hangsUntilCancelled) })
    defer { cleanUp(root) }

    let jobID = JobID(rawValue: UUID())
    let job = Job(
      id: jobID,
      created: Date(),
      title: "resume",
      steps: [Step(
        id: StepID(rawValue: UUID()),
        kind: .composite(CompositeRequest(
          framerate: 30, duration: .seconds(60),
          destination: root.appending(path: "out.mp4"))))])

    // A piece retained from an earlier interrupted attempt — what a resumed
    // composite continues from, and what cancelling a *new* attempt must
    // not touch.
    try FileManager.default.createDirectory(
      at: workspace.resumeDirectory(jobID), withIntermediateDirectories: true)
    try FragmentBuilder.fragmentedFile([UInt32(30)])
      .write(to: workspace.resumeDirectory(jobID).appending(path: "piece-0.mp4"))

    try QueueStore(fileURL: storeURL(for: root)).save([job])
    try await engine.start()

    for _ in 0..<200 {
      if await engine.currentJobs.first?.steps.first?.status == .running { break }
      try await Task.sleep(for: .milliseconds(10))
    }
    #expect(
      await engine.currentJobs.first?.steps.first?.status == .running,
      "precondition: the composite must be genuinely in flight")

    await engine.cancel(job: jobID)
    try await settle(engine)

    #expect(await engine.currentJobs.first?.status == .cancelled)
    #expect(
      FileManager.default.fileExists(
        atPath: workspace.resumeDirectory(jobID).appending(path: "piece-0.mp4").path),
      "resume.md §8: cancellation is the one ending where retention is deliberately kept")

    await engine.flush()
  }

  /// A retention directory naming no job the queue just loaded — the
  /// signature of a lost or corrupted queue store — is otherwise both
  /// unreachable (nothing in the UI names it) and unshowable
  /// (`retainedBytes(forJob:)` needs a `JobID` nothing has any more)
  /// forever, since `removeAll()` deliberately never reaches `resumeRoot`.
  /// `start()` must sweep exactly that case, and nothing else: a job still
  /// in the queue is not an orphan, whatever its status.
  @Test func startSweepsAnOrphanedResumeDirectoryButKeepsAKnownJobs() async throws {
    let root = makeRoot()
    let workspace = Workspace(root: root)
    let engine = QueueEngine(configuration: makeConfiguration(root: root) { FakeHelper(.succeeds) })
    defer { cleanUp(root) }

    // A cancelled job still tracked by the queue — its retained piece must
    // survive the sweep.
    let knownJobID = JobID(rawValue: UUID())
    let knownJob = Job(
      id: knownJobID, created: Date(), title: "resume",
      steps: [Step(
        id: StepID(rawValue: UUID()),
        kind: .composite(CompositeRequest(
          framerate: 30, duration: .seconds(60),
          destination: root.appending(path: "out.mp4"))),
        status: .cancelled)])
    try FileManager.default.createDirectory(
      at: workspace.resumeDirectory(knownJobID), withIntermediateDirectories: true)
    try Data("x".utf8).write(
      to: workspace.resumeDirectory(knownJobID).appending(path: "piece-0.mp4"))

    // An orphan: a resume directory naming a job id the store never heard
    // of — what a lost or corrupted queue store leaves behind.
    let orphanJobID = JobID(rawValue: UUID())
    try FileManager.default.createDirectory(
      at: workspace.resumeDirectory(orphanJobID), withIntermediateDirectories: true)
    try Data("x".utf8).write(
      to: workspace.resumeDirectory(orphanJobID).appending(path: "piece-0.mp4"))

    try QueueStore(fileURL: storeURL(for: root)).save([knownJob])
    try await engine.start()

    #expect(
      FileManager.default.fileExists(atPath: workspace.resumeDirectory(knownJobID).path),
      "a job still in the queue is not an orphan, whatever its status")
    #expect(
      !FileManager.default.fileExists(atPath: workspace.resumeDirectory(orphanJobID).path),
      "a directory naming no loaded job must not survive forever")

    await engine.flush()
  }
}
