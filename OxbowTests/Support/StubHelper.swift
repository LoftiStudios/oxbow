import Foundation
import OxbowKit

/// A helper that reports progress, then either succeeds by writing its
/// output file or blocks until cancelled. `HelperProcessing` is public
/// precisely so tests can substitute one of these.
actor StubHelper: HelperProcessing {
  enum Behaviour: Sendable {
    case succeeds
    case hangsUntilCancelled
  }

  private let behaviour: Behaviour
  private var isCancelled = false
  private var cancelContinuation: CheckedContinuation<Void, Never>?

  init(_ behaviour: Behaviour) { self.behaviour = behaviour }

  func run(
    _ launch: Launch,
    onOutput: @escaping @concurrent @Sendable (ParsedLine) async -> Void)
    async throws -> RunResult
  {
    await onOutput(.status(StepProgress(phase: "Downloading", fraction: 0.5)))

    switch behaviour {
    case .succeeds:
      // The engine's success criterion is a non-empty artifact, not the
      // exit code, so one has to exist.
      let output = launch.arguments.firstIndex(of: "-o").map { launch.arguments[$0 + 1] }
      if let output { FileManager.default.createFile(atPath: output, contents: Data("x".utf8)) }
      return RunResult(status: .exited(0), standardError: "")

    case .hangsUntilCancelled:
      if !isCancelled {
        await withCheckedContinuation { cancelContinuation = $0 }
      }
      return RunResult(status: .signalled(SIGTERM), standardError: "")
    }
  }

  func cancel() async {
    isCancelled = true
    cancelContinuation?.resume()
    cancelContinuation = nil
  }
}
