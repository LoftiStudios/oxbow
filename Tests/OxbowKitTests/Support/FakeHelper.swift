import Foundation
@testable import OxbowKit

/// A helper that writes whatever the test tells it to and reports a chosen status.
actor FakeHelper: HelperProcessing {
  enum Behaviour: Sendable {
    case succeeds
    case failsWithoutArtifact(stderr: String)
    /// Clean exit with an empty output; existence alone must not count as success.
    case leavesAnEmptyArtifact
    /// FFmpeg-only header-without-frames output, reproducing an empty filter result despite a
    /// nonzero file size.
    case writesAFramelessPiece
    /// Waits for cancellation so tests can reliably inspect a running step.
    case hangsUntilCancelled
  }

  private let behaviour: Behaviour
  private var isCancelled = false
  private var cancelContinuation: CheckedContinuation<Void, Never>?

  /// Every `Launch` this helper was handed. The only way to observe which
  /// binary the engine chose for a step, and which output dialect it expected.
  private(set) var launches: [Launch] = []

  init(_ behaviour: Behaviour) { self.behaviour = behaviour }

  /// Records whether shutdown reached the helper, independent of persisted step status.
  var wasCancelled: Bool { isCancelled }

  func run(
    _ launch: Launch,
    onOutput: @escaping @Sendable (ParsedLine) async -> Void)
    async throws -> RunResult
  {
    launches.append(launch)
    await onOutput(.status(StepProgress(phase: "Working", fraction: 0.5)))
    // The narrative output a real helper interleaves with its status lines.
    await onOutput(.log(level: .info, message: "Fetching video info"))
    await onOutput(.ffmpeg("frame= 42 fps=24"))

    switch behaviour {
    case .succeeds:
      // FFmpeg success fixtures need declared frames, not stub bytes, because composite
      // validation rejects header-only pieces.
      switch launch.dialect {
      case .ffmpeg: write(FragmentBuilder.fragmentedFile([1]), for: launch)
      case .helper: write(Data("x".utf8), for: launch)
      }
      return RunResult(status: .exited(0), standardError: "")

    case .failsWithoutArtifact(let stderr):
      return RunResult(status: .exited(134), standardError: stderr)

    case .leavesAnEmptyArtifact:
      write(Data(), for: launch)
      return RunResult(status: .exited(0), standardError: "")

    case .writesAFramelessPiece:
      switch launch.dialect {
      case .ffmpeg: write(FragmentBuilder.fragmentedFile([]), for: launch)
      case .helper: write(Data("x".utf8), for: launch)
      }
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
    guard let output = Self.outputPath(in: launch) else { return }
    FileManager.default.createFile(atPath: output, contents: contents)
  }

  /// CLI output uses `-o`; FFmpeg output is positional.
  private static func outputPath(in launch: Launch) -> String? {
    switch launch.dialect {
    case .helper:
      guard let index = launch.arguments.firstIndex(of: "-o"),
            index + 1 < launch.arguments.count
      else { return nil }
      return launch.arguments[index + 1]
    case .ffmpeg:
      return launch.arguments.last
    }
  }
}
