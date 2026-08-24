import Foundation
@testable import OxbowKit

/// A helper that writes whatever the test tells it to and reports a chosen status.
actor FakeHelper: HelperProcessing {
  enum Behaviour: Sendable {
    case succeeds
    case failsWithoutArtifact(stderr: String)
    /// Exits cleanly having created its output file but never written to it —
    /// what a helper killed mid-write leaves behind. Spec §1.5: an artifact
    /// that exists but is empty is not a success.
    case leavesAnEmptyArtifact
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

  /// Whether `cancel()` was ever called — i.e. whether a real helper would
  /// have had its process group signalled. The only way to observe from the
  /// outside that a shutdown actually reached the child process, since the
  /// engine deliberately leaves the step's status alone on that path.
  var wasCancelled: Bool { isCancelled }

  func run(
    _ launch: Launch,
    onOutput: @escaping @Sendable (ParsedLine) async -> Void)
    async throws -> RunResult
  {
    await onOutput(.status(StepProgress(phase: "Working", fraction: 0.5)))

    switch behaviour {
    case .succeeds:
      // The engine's success criterion is the artifact, so produce one.
      write(Data("x".utf8), for: launch)
      return RunResult(status: .exited(0), standardError: "")

    case .failsWithoutArtifact(let stderr):
      return RunResult(status: .exited(134), standardError: stderr)

    case .leavesAnEmptyArtifact:
      write(Data(), for: launch)
      return RunResult(status: .exited(0), standardError: "")

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

  private nonisolated func write(_ contents: Data, for launch: Launch) {
    guard let output = Self.outputPath(in: launch.arguments) else { return }
    FileManager.default.createFile(atPath: output, contents: contents)
  }

  private static func outputPath(in arguments: [String]) -> String? {
    guard let index = arguments.firstIndex(of: "-o"), index + 1 < arguments.count else { return nil }
    return arguments[index + 1]
  }
}
