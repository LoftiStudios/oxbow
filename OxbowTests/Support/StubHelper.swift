import Foundation
import OxbowKit

/// A helper that reports progress, then either succeeds by writing its
/// output file or blocks until cancelled. `HelperProcessing` is public
/// precisely so tests can substitute one of these.
actor StubHelper: HelperProcessing {
  enum Behaviour: Sendable {
    case succeeds
    case hangsUntilCancelled
    /// Fails the first run and succeeds on every later one, so a retry can
    /// be observed reaching `.done` — a state the first run cannot produce.
    case failsThenSucceeds(Attempts)
  }

  /// Shared by every `StubHelper` one `makeProcess` closure hands out.
  /// `QueueEngine` builds a fresh process per launch, so behaviour that
  /// differs between the first run and the retry needs state outliving a
  /// single instance.
  actor Attempts {
    private var count = 0
    func next() -> Int {
      count += 1
      return count
    }
  }

  private let behaviour: Behaviour
  private var isCancelled = false
  private var cancelContinuation: CheckedContinuation<Void, Never>?

  init(_ behaviour: Behaviour) { self.behaviour = behaviour }

  /// Whether `cancel()` was ever called — i.e. whether a real helper would
  /// have had its process group signalled.
  var wasCancelled: Bool { isCancelled }

  func run(
    _ launch: Launch,
    onOutput: @escaping @concurrent @Sendable (ParsedLine) async -> Void)
    async throws -> RunResult
  {
    await onOutput(.status(StepProgress(phase: "Downloading", fraction: 0.5)))

    switch behaviour {
    case .succeeds:
      return succeed(launch)

    case .hangsUntilCancelled:
      if !isCancelled {
        await withCheckedContinuation { cancelContinuation = $0 }
      }
      return RunResult(status: .signalled(SIGTERM), standardError: "")

    case .failsThenSucceeds(let attempts):
      // Writing no artifact is what makes this a failure: the engine's
      // criterion is a non-empty output file, not the exit code.
      guard await attempts.next() > 1 else {
        return RunResult(status: .exited(1), standardError: "stub failure")
      }
      return succeed(launch)
    }
  }

  func cancel() async {
    isCancelled = true
    cancelContinuation?.resume()
    cancelContinuation = nil
  }

  /// The engine's success criterion is a non-empty artifact, not the exit
  /// code, so one has to exist.
  private func succeed(_ launch: Launch) -> RunResult {
    let output = launch.arguments.firstIndex(of: "-o").map { launch.arguments[$0 + 1] }
    if let output { FileManager.default.createFile(atPath: output, contents: Data("x".utf8)) }
    return RunResult(status: .exited(0), standardError: "")
  }
}
