import Foundation

/// Turns a finished process into either success or a human-readable failure.
///
/// The CLI's `Main` returns void, so nothing sets an exit code; a bad VOD id
/// exits 134 (SIGABRT) with an unhandled .NET exception on stderr. The artifact
/// is therefore the success criterion and the exit code merely corroborates.
public enum FailureInterpreter {

  /// Returns nil when the step succeeded.
  public static func interpret(
    exitStatus: ExitStatus,
    standardError: String,
    artifactExists: Bool)
    -> StepFailure?
  {
    let kind: StepFailure.Kind
    switch exitStatus {
    case .exited(0) where artifactExists:
      return nil
    case .exited(0):
      kind = .noArtifact
    case .exited(let code):
      kind = .exited(code: code)
    case .signalled(let signalNumber):
      kind = .signalled(signalNumber)
    case .waitFailed(let errno):
      // `waitpid` itself failed, so we know nothing about how the process
      // ended. This must never be treated as success, regardless of what
      // artifact happens to be sitting on disk from a previous run — a killed
      // download must never read as done.
      kind = .waitFailed(errno: errno)
    }

    return StepFailure(
      kind: kind,
      summary: summarise(standardError),
      detail: standardError.isEmpty ? nil : standardError)
  }

  /// Known failures get a real sentence; everything else gets the innermost
  /// exception message. A stack trace is never the summary.
  private static func summarise(_ standardError: String) -> String {
    if standardError.contains("vod_manifest_restricted")
      || standardError.contains("unauthorized_entitlements")
    {
      return "This is a subscriber-only VOD."
    }
    if standardError.contains("Invalid VOD, deleted/expired VOD possibly?") {
      return "This VOD no longer exists or has expired."
    }

    let lines = standardError
      .split(separator: "\n", omittingEmptySubsequences: true)
      .map { $0.trimmingCharacters(in: .whitespaces) }

    // .NET nests inner exceptions as `---> Type: message`. The last one is the
    // root cause and carries the most specific message.
    if let innermost = lines.last(where: { $0.hasPrefix("---> ") }),
       let message = innermost.split(separator: ": ", maxSplits: 1).last
    {
      return String(message)
    }

    // Otherwise the first line that is not a stack frame.
    if let first = lines.first(where: { !$0.hasPrefix("at ") }), !first.isEmpty {
      return first
    }

    return "The download tool failed without reporting a reason."
  }
}
