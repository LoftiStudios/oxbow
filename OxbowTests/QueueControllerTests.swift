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
    await controller.enqueue(template, title: "combined")

    try await waitFor(controller) { $0.count == 1 }
    // Require all three requested steps so a dropped render cannot pass.
    #expect(controller.jobs.first?.steps.count == 3)
  }

  /// Check order and dependencies through controller enqueue, not just step count. Chat
  /// precedes render and media so rendering can overlap video download.
  @Test func aMultiOutputTemplateProducesStepsInChatRenderMediaOrder() async throws {
    let (controller, root) = try makeController(.succeeds)
    defer { try? FileManager.default.removeItem(at: root) }
    await controller.start()

    let template = JobTemplate(
      media: .video(VideoRequest(videoID: "2844548319", quality: "", destination: root.appending(path: "out.mp4"))),
      chat: ChatRequest(videoID: "2844548319", format: .html, destination: root.appending(path: "out.html")),
      render: RenderRequest(destination: root.appending(path: "out-render.mp4")))
    await controller.enqueue(template, title: "combined")

    try await waitFor(controller) { $0.count == 1 }
    let steps = try #require(controller.jobs.first?.steps)
    #expect(steps.count == 3)

    guard case .downloadChat(let chatRequest) = steps[0].kind else {
      Issue.record("expected the chat download first; got \(steps[0].kind)")
      return
    }
    guard case .renderChat = steps[1].kind else {
      Issue.record("expected the render step second; got \(steps[1].kind)")
      return
    }
    guard case .downloadVideo = steps[2].kind else {
      Issue.record("expected the video download third; got \(steps[2].kind)")
      return
    }

    #expect(steps[2].dependsOn == [], "media is independent")
    // Also verify JSON coercion for render input.
    #expect(chatRequest.format == .json)
    #expect(steps[1].dependsOn == [steps[0].id], "render depends on the chat download, not the media")
  }

  @Test func aSucceedingJobReachesDone() async throws {
    let (controller, root) = try makeController(.succeeds)
    defer { try? FileManager.default.removeItem(at: root) }
    await controller.start()

    await controller.enqueue(videoTemplate(id: "2844548319", destination: root.appending(path: "out.mp4")), title: "v")

    try await waitFor(controller) { $0.first?.status == .done }
  }

  @Test func cancellingARunningJobSettlesAsCancelledNotFailed() async throws {
    let (controller, root) = try makeController(.hangsUntilCancelled)
    defer { try? FileManager.default.removeItem(at: root) }
    await controller.start()

    await controller.enqueue(videoTemplate(id: "2844548319", destination: root.appending(path: "out.mp4")), title: "v")
    try await waitFor(controller) { $0.first?.status == .running }

    let id = try #require(controller.jobs.first?.id)
    await controller.cancel(job: id)

    try await waitFor(controller) { $0.first?.status == .cancelled }
  }

  @Test func cancellingARunningStepSettlesThatStepAsCancelled() async throws {
    let (controller, root) = try makeController(.hangsUntilCancelled)
    defer { try? FileManager.default.removeItem(at: root) }
    await controller.start()

    await controller.enqueue(videoTemplate(id: "2844548319", destination: root.appending(path: "out.mp4")), title: "v")
    try await waitFor(controller) { $0.first?.status == .running }

    let step = try #require(controller.jobs.first?.steps.first?.id)
    await controller.cancel(step: step)

    try await waitFor(controller) { $0.first?.steps.first?.status == .cancelled }
  }

  /// Two network steps force one to remain queued, exercising its Cancel action.
  @Test func cancellingAQueuedJobLeavesTheRunningOneAlone() async throws {
    let (controller, root) = try makeController(.hangsUntilCancelled)
    defer { try? FileManager.default.removeItem(at: root) }
    await controller.start()

    await controller.enqueue(videoTemplate(id: "2844548319", destination: root.appending(path: "a.mp4")), title: "a")
    await controller.enqueue(videoTemplate(id: "2844548320", destination: root.appending(path: "b.mp4")), title: "b")

    // Find the queued job by status rather than assuming scheduler order.
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

    await controller.enqueue(videoTemplate(id: "2844548319", destination: root.appending(path: "out.mp4")), title: "v")
    try await waitFor(controller) { $0.first?.status == .failed }

    let step = try #require(controller.jobs.first?.steps.first?.id)
    await controller.retry(step: step)

    try await waitFor(controller) { $0.first?.status == .done }
  }

  /// Shutdown must signal the helper before flushing and quitting to avoid orphan processes.
  @Test func shuttingDownSignalsTheHelperStillRunning() async throws {
    // Retain the exact helper instance to inspect cancellation; this job has one invocation.
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

    await controller.enqueue(videoTemplate(id: "2844548319", destination: root.appending(path: "out.mp4")), title: "v")
    try await waitFor(controller) { $0.first?.status == .running }

    await controller.shutDown()

    #expect(await helper.wasCancelled, "quitting must not leave the helper running")
    #expect(
      controller.jobs.first?.steps.first?.status == .running,
      "the step stays running so the next launch reports it as interrupted")
  }

  /// Verify controller metadata-fetch wiring and error propagation; detailed parsing is covered
  /// in OxbowKit.
  @Test func fetchInfoSurfacesAHelperFailureAsAThrownError() async throws {
    let (controller, root) = try makeController(.failsThenSucceeds(StubHelper.Attempts()))
    defer { try? FileManager.default.removeItem(at: root) }
    await controller.start()

    // The stub's first call fails without enqueueing any job.
    await #expect(throws: VideoInfoFetchError.helperFailed(status: .exited(1), standardError: "stub failure")) {
      try await controller.fetchInfo(for: "2844548319")
    }
    // fetchInfo produces no artifact and is not a step: nothing about this
    // call may ever surface in the queue list.
    #expect(controller.jobs.isEmpty)
  }

  /// A reference type, so the escaping observer closures mutate one place
  /// under strict concurrency instead of capturing locals.
  @MainActor private final class Recorder {
    var snapshots: [[Job]] = []
    /// False the moment an observer is handed a snapshot the controller's own
    /// `jobs` has not caught up to.
    var jobsAlwaysMatchedTheSnapshot = true
    var enqueues = 0
  }

  /// Read `controller.jobs` inside the observer to prove state updates precede callbacks.
  @Test func republishesEverySnapshotToTheStatusObserver() async throws {
    let (controller, root) = try makeController(.succeeds)
    defer { try? FileManager.default.removeItem(at: root) }
    let recorder = Recorder()
    controller.onSnapshot = { [weak controller] snapshot in
      recorder.snapshots.append(snapshot)
      if controller?.jobs != snapshot { recorder.jobsAlwaysMatchedTheSnapshot = false }
    }

    await controller.start()
    await controller.enqueue(
      videoTemplate(id: "1", destination: root.appending(path: "out.mp4")),
      title: "t")
    try await waitFor(controller) { $0.count == 1 }

    #expect(recorder.snapshots.contains { $0.count == 1 })
    #expect(recorder.jobsAlwaysMatchedTheSnapshot)
  }

  /// Permission requests follow enqueue events, not launch snapshots that already contain jobs.
  @Test func announcesAnEnqueue() async throws {
    let (controller, root) = try makeController(.succeeds)
    defer { try? FileManager.default.removeItem(at: root) }
    let recorder = Recorder()
    controller.onEnqueue = { recorder.enqueues += 1 }

    await controller.start()
    await controller.enqueue(
      videoTemplate(id: "1", destination: root.appending(path: "out.mp4")),
      title: "t")

    #expect(recorder.enqueues == 1)
  }
}
