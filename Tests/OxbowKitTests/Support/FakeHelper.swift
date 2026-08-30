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
    /// Exits cleanly having written a structurally valid but *frameless*
    /// fragmented MP4 — `ftyp` and `moov`, no `moof`/`mdat` pair. This is
    /// what a composite produces when its filter graph yields nothing, and
    /// the file is neither missing nor zero-length, so every existence-based
    /// success test reads it as a finished piece. Only applied to the FFmpeg
    /// dialect; helper steps in the same job still succeed normally.
    case writesAFramelessPiece
    /// Blocks inside `run` until `cancel()` is called, then reports as
    /// killed by SIGTERM — mirrors a real helper that keeps running until
    /// it is signalled, so a test can reliably catch the step `.running`
    /// before cancelling it.
    case hangsUntilCancelled
  }

  private let behaviour: Behaviour
  private var isCancelled = false
  private var cancelContinuation: CheckedContinuation<Void, Never>?

  /// Every `Launch` this helper was handed. The only way to observe which
  /// binary the engine chose for a step, and which output dialect it expected.
  private(set) var launches: [Launch] = []

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
    launches.append(launch)
    await onOutput(.status(StepProgress(phase: "Working", fraction: 0.5)))
    // The narrative output a real helper interleaves with its status lines.
    await onOutput(.log(level: .info, message: "Fetching video info"))
    await onOutput(.ffmpeg("frame= 42 fps=24"))

    switch behaviour {
    case .succeeds:
      // The engine's success criterion is the artifact, so produce one.
      //
      // FFmpeg-dialect steps get a *fragmented* file carrying one frame, not
      // a stub byte: a composite's piece is checked for declared samples, not
      // just for existence, because a frameless piece would otherwise be
      // concatenated as an empty segment and truncate the delivery
      // (resume.md §12). A one-byte stub is not a shape the real tool can
      // produce there, and standing in for real output with something the
      // production check rejects tests the wrong thing.
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

  /// Where the launched tool would write. The two dialects disagree: the CLI
  /// takes `-o <path>`, while FFmpeg takes its output as a trailing positional
  /// argument with no flag at all.
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
