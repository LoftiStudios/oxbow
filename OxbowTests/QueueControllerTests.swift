import Foundation
import Testing
import OxbowKit
@testable import Oxbow

@MainActor
@Suite("Queue controller")
struct QueueControllerTests {

  /// A controller over a real engine with stub processes: real scheduling
  /// and real state transitions, no subprocesses and no network.
  private func makeController(_ behaviour: StubHelper.Behaviour) throws -> (QueueController, URL) {
    let root = URL(filePath: NSTemporaryDirectory()).appending(path: "oxbow-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let configuration = QueueEngine.Configuration(
      helperExecutable: root.appending(path: "helper"),
      ffmpegPath: root.appending(path: "ffmpeg"),
      workspace: Workspace(root: root.appending(path: "workspace")),
      store: QueueStore(fileURL: root.appending(path: "queue.json")),
      makeProcess: { StubHelper(behaviour) })
    return (QueueController(configuration: configuration), root)
  }

  /// Polls rather than sleeping a fixed interval: snapshots arrive
  /// asynchronously, and a fixed sleep is either flaky or slow.
  private func waitFor(
    _ controller: QueueController,
    timeout: Duration = .seconds(5),
    until condition: ([Job]) -> Bool)
    async throws
  {
    let deadline = ContinuousClock().now + timeout
    while ContinuousClock().now < deadline {
      if condition(controller.jobs) { return }
      try await Task.sleep(for: .milliseconds(20))
    }
    Issue.record("condition not met within \(timeout); jobs = \(controller.jobs)")
  }

  private func videoTemplate(id: String, destination: URL) -> JobTemplate {
    JobTemplate(media: .video(VideoRequest(videoID: id, quality: "", destination: destination)))
  }

  @Test func enqueueingAComposedTemplateProducesAJobWithTheExpectedStepCount() async throws {
    let (controller, root) = try makeController(.succeeds)
    defer { try? FileManager.default.removeItem(at: root) }
    await controller.start()

    let template = JobTemplate(
      media: .video(VideoRequest(videoID: "2844548319", quality: "", destination: root.appending(path: "out.mp4"))),
      chat: ChatRequest(videoID: "2844548319", format: .html, destination: root.appending(path: "out.html")),
      render: RenderRequest(destination: root.appending(path: "out-render.mp4")))
    controller.enqueue(template, title: "combined")

    try await waitFor(controller) { $0.count == 1 }
    // Video + chat + render: three steps, not merely "at least one" — a
    // template that silently dropped the render step would still satisfy a
    // weaker `steps.count > 0` assertion.
    #expect(controller.jobs.first?.steps.count == 3)
  }

  /// Weaker assertions here (e.g. "steps.count == 3") pass just as well for
  /// an implementation that emits the right steps in the wrong order, or
  /// with `dependsOn` wired to the wrong step. `JobTemplate.makeJob` already
  /// has exhaustive coverage of that shape in `JobTemplateTests`; this test
  /// exists only to prove the controller forwards the template to the engine
  /// unmangled, so it checks the same shape end to end through the real
  /// `QueueController.enqueue` → `QueueEngine.enqueue` path.
  @Test func aMultiOutputTemplateProducesStepsInMediaChatRenderOrder() async throws {
    let (controller, root) = try makeController(.succeeds)
    defer { try? FileManager.default.removeItem(at: root) }
    await controller.start()

    let template = JobTemplate(
      media: .video(VideoRequest(videoID: "2844548319", quality: "", destination: root.appending(path: "out.mp4"))),
      chat: ChatRequest(videoID: "2844548319", format: .html, destination: root.appending(path: "out.html")),
      render: RenderRequest(destination: root.appending(path: "out-render.mp4")))
    controller.enqueue(template, title: "combined")

    try await waitFor(controller) { $0.count == 1 }
    let steps = try #require(controller.jobs.first?.steps)
    #expect(steps.count == 3)

    guard case .downloadVideo = steps[0].kind else {
      Issue.record("expected the video download first; got \(steps[0].kind)")
      return
    }
    guard case .downloadChat(let chatRequest) = steps[1].kind else {
      Issue.record("expected the chat download second; got \(steps[1].kind)")
      return
    }
    guard case .renderChat = steps[2].kind else {
      Issue.record("expected the render step third; got \(steps[2].kind)")
      return
    }

    #expect(steps[0].dependsOn == nil, "media is independent")
    // A render pairing forces JSON regardless of what the caller asked for
    // (JobTemplate.renderInput) - asserting this, not just the step order,
    // rules out an implementation that forwarded a mangled copy of the chat
    // request.
    #expect(chatRequest.format == .json)
    #expect(steps[2].dependsOn == steps[1].id, "render depends on the chat download, not the media")
  }

  @Test func aSucceedingJobReachesDone() async throws {
    let (controller, root) = try makeController(.succeeds)
    defer { try? FileManager.default.removeItem(at: root) }
    await controller.start()

    controller.enqueue(videoTemplate(id: "2844548319", destination: root.appending(path: "out.mp4")), title: "v")

    try await waitFor(controller) { $0.first?.status == .done }
  }

  @Test func cancellingARunningJobSettlesAsCancelledNotFailed() async throws {
    let (controller, root) = try makeController(.hangsUntilCancelled)
    defer { try? FileManager.default.removeItem(at: root) }
    await controller.start()

    controller.enqueue(videoTemplate(id: "2844548319", destination: root.appending(path: "out.mp4")), title: "v")
    try await waitFor(controller) { $0.first?.status == .running }

    let id = try #require(controller.jobs.first?.id)
    await controller.cancel(job: id)

    try await waitFor(controller) { $0.first?.status == .cancelled }
  }

  @Test func cancellingARunningStepSettlesThatStepAsCancelled() async throws {
    let (controller, root) = try makeController(.hangsUntilCancelled)
    defer { try? FileManager.default.removeItem(at: root) }
    await controller.start()

    controller.enqueue(videoTemplate(id: "2844548319", destination: root.appending(path: "out.mp4")), title: "v")
    try await waitFor(controller) { $0.first?.status == .running }

    let step = try #require(controller.jobs.first?.steps.first?.id)
    await controller.cancel(step: step)

    try await waitFor(controller) { $0.first?.steps.first?.status == .cancelled }
  }

  /// The state a queued job's Cancel button exists for. Both steps are
  /// downloads and the scheduler admits one step per resource class, so the
  /// second necessarily waits for the whole of the first.
  @Test func cancellingAQueuedJobLeavesTheRunningOneAlone() async throws {
    let (controller, root) = try makeController(.hangsUntilCancelled)
    defer { try? FileManager.default.removeItem(at: root) }
    await controller.start()

    controller.enqueue(videoTemplate(id: "2844548319", destination: root.appending(path: "a.mp4")), title: "a")
    controller.enqueue(videoTemplate(id: "2844548320", destination: root.appending(path: "b.mp4")), title: "b")

    // By shape, not by index: the two enqueues are separate tasks, so which
    // job lands first is not ordered.
    try await waitFor(controller) { jobs in
      jobs.count == 2
        && jobs.contains { $0.status == .running }
        && jobs.contains { $0.status == .queued }
    }

    let queued = try #require(controller.jobs.first { $0.status == .queued })
    await controller.cancel(job: queued.id)

    try await waitFor(controller) { jobs in
      jobs.first { $0.id == queued.id }?.status == .cancelled
    }
    #expect(controller.jobs.contains { $0.status == .running })
  }

  /// Reaching `.done` is the assertion: the first run wrote no artifact, so
  /// only a second one can produce it.
  @Test func retryingAFailedStepRunsItAgain() async throws {
    let (controller, root) = try makeController(.failsThenSucceeds(StubHelper.Attempts()))
    defer { try? FileManager.default.removeItem(at: root) }
    await controller.start()

    controller.enqueue(videoTemplate(id: "2844548319", destination: root.appending(path: "out.mp4")), title: "v")
    try await waitFor(controller) { $0.first?.status == .failed }

    let step = try #require(controller.jobs.first?.steps.first?.id)
    await controller.retry(step: step)

    try await waitFor(controller) { $0.first?.status == .done }
  }

  /// The quit path the app delegate actually calls. A `flush()`-only quit
  /// exited with the helper still running, orphaning `TwitchDownloaderCLI`
  /// and the FFmpeg it spawned; `shutDown()` has to signal it first.
  @Test func shuttingDownSignalsTheHelperStillRunning() async throws {
    // Built inline rather than through `makeController`: the test has to hold
    // the very `StubHelper` the engine launched in order to ask it whether it
    // was signalled. Handing back the same instance every time is safe here —
    // the job has exactly one step, so it is only ever launched once.
    let helper = StubHelper(.hangsUntilCancelled)
    let root = URL(filePath: NSTemporaryDirectory()).appending(path: "oxbow-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let controller = QueueController(configuration: QueueEngine.Configuration(
      helperExecutable: root.appending(path: "helper"),
      ffmpegPath: root.appending(path: "ffmpeg"),
      workspace: Workspace(root: root.appending(path: "workspace")),
      store: QueueStore(fileURL: root.appending(path: "queue.json")),
      makeProcess: { helper }))
    await controller.start()

    controller.enqueue(videoTemplate(id: "2844548319", destination: root.appending(path: "out.mp4")), title: "v")
    try await waitFor(controller) { $0.first?.status == .running }

    await controller.shutDown()

    #expect(await helper.wasCancelled, "quitting must not leave the helper running")
    #expect(
      controller.jobs.first?.steps.first?.status == .running,
      "the step stays running so the next launch reports it as interrupted")
  }

  /// `fetchInfo` runs outside the queue entirely - this is the one place
  /// that exercises it through `QueueController` rather than
  /// `VideoInfoFetcher` directly (already covered exhaustively by
  /// `VideoInfoFetcherTests` in OxbowKit). It only has to prove the
  /// controller wires the helper executable and a fresh process through
  /// correctly and surfaces a failure as a thrown error, not swallow it or
  /// return some placeholder value.
  @Test func fetchInfoSurfacesAHelperFailureAsAThrownError() async throws {
    let (controller, root) = try makeController(.failsThenSucceeds(StubHelper.Attempts()))
    defer { try? FileManager.default.removeItem(at: root) }
    await controller.start()

    // No job is ever enqueued: `.failsThenSucceeds`'s first attempt always
    // fails, so this call alone exercises the failure path without
    // depending on queue scheduling at all.
    await #expect(throws: VideoInfoFetchError.helperFailed(status: .exited(1), standardError: "stub failure")) {
      try await controller.fetchInfo(for: "2844548319")
    }
    // fetchInfo produces no artifact and is not a step: nothing about this
    // call may ever surface in the queue list.
    #expect(controller.jobs.isEmpty)
  }
}
