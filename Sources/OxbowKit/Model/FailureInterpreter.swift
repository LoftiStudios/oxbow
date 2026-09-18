import Foundation

/// Interpret process completion using artifact validity and exit evidence. The helper's exit
/// status alone does not establish success.
public enum FailureInterpreter {

  /// Returns nil when the step succeeded.
  public static func interpret(
    exitStatus: ProcessExitStatus,
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
      // A waitpid failure leaves process outcome unknown; never accept an artifact as proof of
      // success in this case.
      kind = .waitFailed(errno: errno)
    }

    return StepFailure(
      kind: kind,
      summary: summarise(standardError),
      detail: standardError.isEmpty ? nil : standardError)
  }

  /// Shared summary matched by automatic restriction policy. Match the CLI's Insufficient
  /// access to VOD wording as well as Twitch manifest errors; the CLI masks the original 403.
  /// Its wording can cover other credential restrictions too. Oxbow offers no OAuth sign-in
  /// remedy.
  public static let subscriberOnlySummary = "This is a subscriber-only VOD."

  /// Known failures get a real sentence; everything else gets the innermost
  /// exception message. A stack trace is never the summary.
  private static func summarise(_ standardError: String) -> String {
    // Match both CLI and direct-manifest restriction messages.
    if standardError.contains("Insufficient access to VOD")
      || standardError.contains("vod_manifest_restricted")
      || standardError.contains("unauthorized_entitlements")
    {
      return subscriberOnlySummary
    }
    // Distinguish a clip's missing parent VOD from a missing VOD itself: clip video remains
    // downloadable, but its broadcast chat cannot be reconstructed.
    if standardError.contains("Invalid VOD for clip, deleted/expired VOD possibly?") {
      return """
        This clip's original broadcast is no longer on Twitch, so its chat \
        cannot be downloaded.
        """
    }
    if standardError.contains("Invalid VOD, deleted/expired VOD possibly?") {
      return "This VOD no longer exists or has expired."
    }

    let lines = standardError
      .split(separator: "\n", omittingEmptySubsequences: true)
      .map { $0.trimmingCharacters(in: .whitespaces) }
      // Strip FFmpeg component/address prefixes before selecting a summary.
      .map { line in
        line.replacing(/^\[[^\]]+ @ 0x[0-9a-f]+\]\s*/, with: "")
      }

    // Use the last .NET inner-exception message; remove the ---> marker even when no colon
    // follows.
    if let innermost = lines.last(where: { $0.hasPrefix("---> ") }) {
      let stripped = innermost.dropFirst("---> ".count)
      let message = stripped.split(separator: ": ", maxSplits: 1).last ?? stripped
      return String(message)
    }

    // Otherwise the first line that is not a stack frame.
    if let first = lines.first(where: { !$0.hasPrefix("at ") }), !first.isEmpty {
      return first
    }

    return "The tool failed without reporting a reason."
  }
}
