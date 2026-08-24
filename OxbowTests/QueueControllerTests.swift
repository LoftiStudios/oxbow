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

  @Test func enqueueingAVideoAddsAJob() async throws {
    let (controller, root) = try makeController(.succeeds)
    defer { try? FileManager.default.removeItem(at: root) }
    await controller.start()

    try controller.enqueueVideo(
      urlText: "https://www.twitch.tv/videos/2844548319",
      destination: root.appending(path: "out.mp4"))

    try await waitFor(controller) { $0.count == 1 }
    #expect(controller.jobs.first?.steps.count == 1)
  }

  @Test func rejectsSomethingThatIsNotAVideoURL() async throws {
    let (controller, root) = try makeController(.succeeds)
    defer { try? FileManager.default.removeItem(at: root) }
    await controller.start()

    #expect(throws: QueueController.IntakeError.notAVideoURL) {
      try controller.enqueueVideo(urlText: "https://www.twitch.tv/leighxp", destination: root.appending(path: "out.mp4"))
    }
    #expect(controller.jobs.isEmpty)
  }

  @Test func aSucceedingJobReachesDone() async throws {
    let (controller, root) = try makeController(.succeeds)
    defer { try? FileManager.default.removeItem(at: root) }
    await controller.start()

    try controller.enqueueVideo(urlText: "2844548319", destination: root.appending(path: "out.mp4"))

    try await waitFor(controller) { $0.first?.status == .done }
  }

  @Test func cancellingARunningJobSettlesAsCancelledNotFailed() async throws {
    let (controller, root) = try makeController(.hangsUntilCancelled)
    defer { try? FileManager.default.removeItem(at: root) }
    await controller.start()

    try controller.enqueueVideo(urlText: "2844548319", destination: root.appending(path: "out.mp4"))
    try await waitFor(controller) { $0.first?.status == .running }

    let id = try #require(controller.jobs.first?.id)
    await controller.cancel(job: id)

    try await waitFor(controller) { $0.first?.status == .cancelled }
  }
}
