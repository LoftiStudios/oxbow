import Darwin
import Foundation
import Testing
@testable import OxbowKit

@Suite("QueueEngine", .serialized)
struct QueueEngineTests {

  private func makeRoot() -> URL {
    URL(filePath: NSTemporaryDirectory()).appending(path: "oxbow-engine-\(UUID().uuidString)")
  }

  /// Keep queue persistence outside swept workspace; derive its path for deterministic cleanup.
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


  /// Fixture startup must preserve saved running progress and start no work. Normal
  /// reconciliation and scheduling would destroy the screenshot fixture's staged state.
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

  /// Delivery is outside workspace and must survive its sweep. Callers must clean this separate
  /// path explicitly.
  private func makeChatAndRenderTemplate() -> (template: JobTemplate, renderDestination: URL) {
    let destination = URL(filePath: NSTemporaryDirectory())
      .appending(path: "render-\(UUID().uuidString).mp4")
    let template = JobTemplate(
      chat: ChatRequest(videoID: "2844548319", format: .json),
      render: RenderRequest(destination: destination))
    return (template, destination)
  }

  /// Assert logs on a failed step, whose workspace survives; successful jobs intentionally
  /// remove their logs.
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

  /// One status update below the heartbeat interval must not enter the diagnostic log.
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

  /// Successful delivery removes logs with the workspace.
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


  /// Retry a cancelled multi-step job through completion; restarting only one cancelled sibling
  /// would stall it.
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

  /// Removing a job must reclaim retained logs and intermediates.
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

  /// Removing a queue row must never delete the user's delivered download.
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

  /// Without replacement permission, preserve collisions and record the actual numbered
  /// delivery path.
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

  /// Explicit Replace permission must overwrite the chosen destination.
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

  /// Removing running work must cancel its helper before deleting its workspace.
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

  /// A nonempty MP4 header can contain zero frames despite exit 0. Reject pieces without
  /// declared samples so assembly cannot silently truncate at the resume seam.
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

  /// Composite jobs deliver only assembly output; all earlier artifacts are intermediate.
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

    // Successful delivery removes workspace artifacts and retained pieces, clearing their
    // claims in the same actor turn. Done jobs bypass later reconciliation, so dangling claims
    // must not survive here.
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

    // Only assembly output remains after cleanup.
    let enumerator = FileManager.default.enumerator(atPath: root.path)
    let delivered = (enumerator?.allObjects as? [String] ?? []).filter { $0.hasSuffix(".mp4") }
    #expect(Set(delivered) == ["out.mp4"])

    await engine.flush()
  }

  /// After retention cleanup, composite Finder reveal falls back to delivered assembly output.
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

  /// Follow assembly specifically: a library caller may also deliver chat earlier in step
  /// order, making `deliveredFiles.first` incorrect.
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
    // Chat delivers before assembly, distinguishing the specific assembly lookup from first
    // output.
    #expect(job.deliveredFiles.count == 2)
    #expect(await engine.revealTarget(forJob: job.id) == .delivered(videoDestination))

    await engine.flush()
  }

  /// Verify the assembled file still exists before offering reveal.
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

  /// Clear retained-piece claims explicitly; workspace containment excludes retention, so the
  /// ordinary cleanup loop cannot do it.
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

  /// Hold assembly running after composite completes. The destination must remain absent,
  /// proving composite cannot deliver early to their shared path.
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

    // Wait for composite done and assembly running before inspecting delivery.
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

  /// Restart through a second engine to prove completed jobs stay done after their
  /// intermediates were intentionally deleted.
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

    // A fresh engine's helper factory is a tripwire: done jobs must launch nothing.
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

    // Deleted chat intermediates must also lose their artifact claims.
    #expect(reloaded[0].steps[0].artifact == nil, "the discarded intermediate must not be claimed")
    #expect(reloaded[0].steps[1].artifact == renderDestination)
    #expect(
      FileManager.default.fileExists(atPath: renderDestination.path),
      "the file the user actually asked for must survive the restart")

    #expect(await restarted.isIdle, "there must be nothing left to do")

    await restarted.flush()
  }

  /// Composite media with no destination is removed after delivery.
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

    // Deleted media intermediates must also lose their artifact claims.
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

  /// Cancellation must not be overwritten by the in-flight helper's signalled failure.
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

  /// Force deletion failure with `uchg`: open handles and read-only files can still be unlinked
  /// on APFS. Step logs survive step-directory removal and must report the failure.
  @Test func aStepTeardownFailureIsRecordedInThatStepsOwnLog() async throws {
    let (engine, root) = makeEngine(.hangsUntilCancelled)
    defer { cleanUp(root) }
    let workspace = Workspace(root: root)

    try await engine.start()
    await engine.enqueue(
      JobTemplate(chat: ChatRequest(videoID: "2844548319", format: .json)), title: "test")

    // Enqueue prepares the step directory synchronously before returning.
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

    // Poll for the asynchronous failure-log write; idle does not imply it has landed.
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

  /// Job cleanup failures must be recorded outside the job tree that cleanup removes.
  @Test func aJobTeardownFailureIsRecordedInTheWorkspaceLevelLog() async throws {
    let (engine, root) = makeEngine(.hangsUntilCancelled)
    defer { cleanUp(root) }
    let workspace = Workspace(root: root)

    try await engine.start()
    await engine.enqueue(
      JobTemplate(chat: ChatRequest(videoID: "2844548319", format: .json)), title: "test")

    let jobID = try #require(await engine.currentJobs.first?.id)

    // Place the stubborn file beside artifacts/logs to isolate reporting; sibling cleanup is
    // covered in WorkspaceTests.
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

  /// Job cancellation preserves completed steps and must not report killed steps as failed.
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

    // Let chat finish, then hold render and video running together while composite remains
    // queued. Cancel only after reaching that state.
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

  /// Retry must relaunch the failure and release its blocked dependent.
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

  /// Failed delivery must leave the step failed and retain its workspace artifact.
  @Test func aFailedMoveFailsTheStepAndPreservesTheArtifact() async throws {
    let (engine, root) = makeEngine(.succeeds)
    defer { cleanUp(root) }

    try await engine.start()

    // A regular file at the destination's parent path forces directory creation to fail
    // deterministically.
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

    // Retaining the artifact proves failed delivery did not trigger successful-job cleanup.
    let artifact = Workspace(root: root).artifactsDirectory(job.id).appending(path: "video.mp4")
    #expect(
      FileManager.default.fileExists(atPath: artifact.path),
      "the only copy of the artifact must survive a failed move")

    await engine.flush()
  }

  /// Cancelling must not leave done steps pointing at deleted intermediates that retry would
  /// consume.
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

  /// Reject zero-byte artifacts left by killed helpers.
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

  /// Apply the same nonempty-artifact rule during reconciliation.
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

  /// Persisted running downloads become interrupted failures; retry must also release their
  /// dependents.
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

  /// Shutdown signals helpers but persists interrupted steps as running for next-launch
  /// reconciliation, not as user cancellation or process crashes.
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

  /// Do not admit new work while quit is held open for shutdown.
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

  /// Use a real helper/child pair to verify shutdown reaches the entire process group; a fake
  /// only proves `cancel()` was called.
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

    // Poll until launchd reaps the killed grandchild; `kill(pid, 0)` still sees zombies.
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

  /// Resume fixture with a single composite step and matching empty dependency/input lists,
  /// isolating resume from full job wiring.
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

    /// Synthetic retained piece with one fragment declaring the requested frame count.
    func writePiece(index: Int, frames: Int) throws {
      try FileManager.default.createDirectory(
        at: workspace.resumeDirectory(job.id), withIntermediateDirectories: true)
      let data = FragmentBuilder.fragmentedFile([UInt32(frames)])
      try data.write(
        to: workspace.resumeDirectory(job.id).appending(path: "piece-\(index).mp4"))
    }

    /// Seed a fingerprint directly to exercise source mismatches without two real encodes.
    func writeFingerprint(byteCount: Int, duration: Duration) throws {
      try FileManager.default.createDirectory(
        at: workspace.resumeDirectory(job.id), withIntermediateDirectories: true)
      try SourceFingerprint(byteCount: byteCount, duration: duration)
        .write(to: workspace.resumeDirectory(job.id).appending(path: "source.json"))
    }

    /// Write an exact-size source fixture for fingerprint comparisons.
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

    /// Completed sidecar layout: ftyp, mdat, then complete moov.
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

    /// Exercise composite context with a video dependency and the same source-change error
    /// translation used by launch.
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

    /// Pre-assembly job with completed video, render, and composite artifacts; ordered for
    /// index-based fixture access.
    func assembleReadyJob() -> Job {
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
        // Assembly does not read this piece directly, but the wiring guard requires an artifact
        // for each dependency.
        artifact: workspace.resumeDirectory(job.id).appending(path: "piece-0.mp4"))
      let assembleStep = Step(
        id: StepID(rawValue: UUID()),
        kind: .assemble(AssembleRequest(destination: workspace.root.appending(path: "out.mp4"))),
        dependsOn: [compositeStep.id])
      return Job(id: job.id, created: job.created, title: job.title,
                 steps: [videoStep, renderStep, compositeStep, assembleStep])
    }

    /// Builds the assemble step's context the way `launch` does, and nothing
    /// else — no engine tick, no process.
    @discardableResult
    func buildAssembleContext() -> StepContext? {
      let wired = assembleReadyJob()
      return try? engine.makeContext(job: wired, step: wired.steps[3])
    }

    /// Load with `runsWork: false`, then seed artifacts and retry the failed target. Retry
    /// exercises real launch without another startup sweep; launch-time context work completes
    /// synchronously before it returns.
    func launchThroughTheEngine(
      stepIndex: Int = 3)
      async throws -> (video: URL, render: URL, launched: StepID)
    {
      var wired = assembleReadyJob()
      wired.steps[stepIndex].status = .failed(
        StepFailure(kind: .noArtifact, summary: "seeded so retry can requeue it"))
      try store.save([wired])
      try await engine.start(runsWork: false)

      let artifacts = try workspace.prepareArtifacts(job: job.id)
      let video = artifacts.appending(path: "video.mp4")
      let render = artifacts.appending(path: "render.mp4")
      try Data("x".utf8).write(to: video)
      try Data("x".utf8).write(to: render)

      await engine.retry(job: job.id)
      return (video, render, wired.steps[stepIndex].id)
    }

    /// Positive control: a launch that never ran would satisfy file-survival assertions
    /// vacuously.
    func isRunning(_ step: StepID) async -> Bool {
      await engine.currentJobs
        .flatMap(\.steps)
        .first { $0.id == step }?.status == .running
    }

    /// Run through actual completion so engine delivery cleanup—not direct context
    /// construction—clears retention.
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

  private func makeHarness(
    _ makeProcess: @escaping @Sendable () -> HelperProcessing = { FakeHelper(.succeeds) })
    throws -> ResumeHarness
  {
    let root = makeRoot()
    let workspace = Workspace(root: root)
    let engine = QueueEngine(configuration: makeConfiguration(root: root, makeProcess: makeProcess))

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
    // Compare paths; directory-flavored URLs with trailing slashes are not necessarily equal to
    // file-flavored URLs naming the same path.
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
    // The cap reset must recreate an empty directory; surviving old pieces would be
    // concatenated with fresh output.
    let contents = try FileManager.default.contentsOfDirectory(
      atPath: harness.workspace.resumeDirectory(harness.job.id).path)
    #expect(contents.isEmpty)
  }

  /// Discard header-only zero-frame pieces so they consume neither a retry slot nor a concat
  /// segment.
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

  /// Verify the engine computes absent sidecar as unusable, rather than merely relying on the
  /// context default.
  @Test func aFirstAttemptHasNoUsableSidecar() async throws {
    let harness = try makeHarness()
    defer { harness.tearDown() }

    let context = try harness.engineContext(forCompositeOf: harness.job)

    #expect(!context.hasUsableSidecar)
  }

  /// A nonempty sidecar may still lack a complete moov after SIGKILL.
  @Test func aRetryWithACorruptSidecarReportsItAsUnusable() async throws {
    let harness = try makeHarness()
    defer { harness.tearDown() }
    try harness.writePiece(index: 0, frames: 90)
    try harness.writeCorruptSidecar()

    let context = try harness.engineContext(forCompositeOf: harness.job)

    #expect(!context.hasUsableSidecar)
  }

  /// Completed sidecars must be recognized so resume leaves them untouched.
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

  /// Missing fingerprints must refuse resume, just like mismatches. A failed fingerprint write
  /// must not silently authorize an unverifiable source.
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

  /// Launch assembly with a hanging helper to prove inputs are removed before encoding, not by
  /// eventual job cleanup. This bounds recovery peak disk use.
  @Test func launchingAssembleDropsTheRefetchedInputsFirst() async throws {
    let harness = try makeHarness { FakeHelper(.hangsUntilCancelled) }
    defer { harness.tearDown() }

    let (video, render, assemble) = try await harness.launchThroughTheEngine()

    #expect(await harness.isRunning(assemble), "control: assemble must really have launched")
    #expect(!FileManager.default.fileExists(atPath: video.path),
            "the re-fetched video must be gone before assemble writes — resume.md §5")
    #expect(!FileManager.default.fileExists(atPath: render.path),
            "the re-fetched chat render must be gone before assemble writes — resume.md §5")
    await harness.engine.cancel(job: harness.job.id)
  }

  /// Context construction must preserve files; input cleanup belongs to launch.
  @Test func buildingAnAssembleContextDestroysNothing() async throws {
    let harness = try makeHarness()
    defer { harness.tearDown() }
    let video = try harness.writeVideoArtifact(byteCount: 10)
    let render = try harness.writeRenderArtifact(byteCount: 10)

    let context = try #require(harness.buildAssembleContext())

    #expect(FileManager.default.fileExists(atPath: video.path),
            "makeContext must not delete the video")
    #expect(FileManager.default.fileExists(atPath: render.path),
            "makeContext must not delete the chat render")
    // The control: the call really did build an assemble context, so the two
    // survivals above cannot be explained by an early throw.
    #expect(context.outputFile.lastPathComponent == "assemble.mp4")
  }

  /// Composite launch must retain the inputs it is about to read; only assembly spends them.
  @Test func launchingACompositeSpendsNothing() async throws {
    let harness = try makeHarness { FakeHelper(.hangsUntilCancelled) }
    defer { harness.tearDown() }

    let (video, render, composite) = try await harness.launchThroughTheEngine(stepIndex: 2)

    // Positive control against a harness that launches nothing.
    #expect(await harness.isRunning(composite), "control: the composite must really have launched")
    #expect(FileManager.default.fileExists(atPath: video.path),
            "a composite must still have the video it is about to read")
    #expect(FileManager.default.fileExists(atPath: render.path),
            "a composite must still have the chat render it is about to read")
    await harness.engine.cancel(job: harness.job.id)
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

  /// Reveal retention directory and ordered pieces, outside workspace.
  @Test func retainedFileURLsReportTheDirectoryAndItsPiecesInOrder() async throws {
    let harness = try makeHarness()
    defer { harness.tearDown() }
    try harness.writePiece(index: 1, frames: 30)
    try harness.writePiece(index: 0, frames: 30)

    let (directory, pieces) = await harness.engine.retainedFileURLs(forJob: harness.job.id)

    #expect(directory == harness.workspace.resumeDirectory(harness.job.id))
    #expect(pieces.map(\.lastPathComponent) == ["piece-0.mp4", "piece-1.mp4"])
  }

  /// Before the first fragment exists, the prepared retention directory is still a valid Finder
  /// target.
  @Test func retainedFileURLsReportTheDirectoryEvenWithNoPiecesYet() async throws {
    let harness = try makeHarness()
    defer { harness.tearDown() }

    let (directory, pieces) = await harness.engine.retainedFileURLs(forJob: harness.job.id)

    #expect(directory == harness.workspace.resumeDirectory(harness.job.id))
    #expect(pieces.isEmpty)
  }

  /// When retention exists, reveal its actual contents.
  @Test func revealTargetReportsRetainedPiecesWhileTheyAreOnDisk() async throws {
    let harness = try makeHarness()
    defer { harness.tearDown() }
    try harness.writePiece(index: 0, frames: 30)

    let target = await harness.engine.revealTarget(forJob: harness.job.id)

    // Use the filesystem-returned URL form to avoid `/var` versus `/private/var` mismatches.
    let (directory, pieces) = await harness.engine.retainedFileURLs(forJob: harness.job.id)
    #expect(target == .retained(directory: directory, pieces: pieces))
    #expect(pieces.map(\.lastPathComponent) == ["piece-0.mp4"])
  }

  /// Never-started composites have nothing to reveal.
  @Test func revealTargetIsNilBeforeTheCompositeHasEverStarted() async throws {
    let harness = try makeHarness()
    defer { harness.tearDown() }

    #expect(await harness.engine.revealTarget(forJob: harness.job.id) == nil)
  }

  /// Cancellation preserves retention for a later retry.
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

    // Cancelling a resumed attempt must preserve earlier pieces.
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

  /// Launch removes retention directories absent from the loaded queue; all known job IDs
  /// survive regardless of status.
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
