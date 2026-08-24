import Foundation
import Testing
@testable import OxbowKit

/// A helper that writes whatever the test tells it to and reports a chosen status.
actor FakeHelper: HelperProcessing {
  enum Behaviour: Sendable {
    case succeeds
    case failsWithoutArtifact(stderr: String)
  }

  private let behaviour: Behaviour
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
    }
  }

  func cancel() async {}

  private static func outputPath(in arguments: [String]) -> String? {
    guard let index = arguments.firstIndex(of: "-o"), index + 1 < arguments.count else { return nil }
    return arguments[index + 1]
  }
}

@Suite("QueueEngine", .serialized)
struct QueueEngineTests {

  private func makeEngine(_ behaviour: FakeHelper.Behaviour) -> (QueueEngine, URL) {
    let root = URL(filePath: NSTemporaryDirectory())
      .appending(path: "oxbow-engine-\(UUID().uuidString)")
    let engine = QueueEngine(configuration: .init(
      helperExecutable: URL(filePath: "/usr/bin/true"),
      ffmpegPath: URL(filePath: "/usr/bin/true"),
      workspace: Workspace(root: root),
      store: QueueStore(fileURL: root.appending(path: "queue.json")),
      makeProcess: { FakeHelper(behaviour) }))
    return (engine, root)
  }

  private var chatAndRender: JobTemplate {
    .chatAndRender(
      ChatRequest(videoID: "2844548319", format: .json),
      RenderRequest(destination: URL(filePath: NSTemporaryDirectory())
        .appending(path: "render-\(UUID().uuidString).mp4")))
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
    defer { try? FileManager.default.removeItem(at: root) }

    try await engine.start()
    await engine.enqueue(chatAndRender, title: "test")
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
    defer { try? FileManager.default.removeItem(at: root) }

    try await engine.start()
    await engine.enqueue(chatAndRender, title: "test")
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

  @Test func persistsAcrossRestart() async throws {
    let (engine, root) = makeEngine(.succeeds)
    defer { try? FileManager.default.removeItem(at: root) }

    try await engine.start()
    await engine.enqueue(chatAndRender, title: "persisted")
    try await settle(engine)
    await engine.flush()

    let reloaded = try QueueStore(fileURL: root.appending(path: "queue.json")).load()
    #expect(reloaded.count == 1)
    #expect(reloaded[0].title == "persisted")
  }

  @Test func publishesSnapshotsAsWorkProgresses() async throws {
    let (engine, root) = makeEngine(.succeeds)
    defer { try? FileManager.default.removeItem(at: root) }

    try await engine.start()

    let received = CollectedSnapshots()
    let observer = Task {
      for await snapshot in await engine.makeSnapshots() {
        await received.append(snapshot)
        if snapshot.first?.status == .done { break }
      }
    }

    await engine.enqueue(chatAndRender, title: "test")
    try await settle(engine)
    observer.cancel()

    #expect(await received.count > 1, "expected more than one snapshot")

    // Cancels the debounced save timer so it cannot recreate the workspace
    // root after this test's `defer` has already removed it.
    await engine.flush()
  }
}
