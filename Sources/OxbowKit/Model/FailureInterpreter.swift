import Foundation

/// Turns a finished process into either success or a human-readable failure.
///
/// The CLI's `Main` returns void, so nothing sets an exit code; a bad VOD id
/// exits 134 (SIGABRT) with an unhandled .NET exception on stderr. The artifact
/// is therefore the success criterion and the exit code merely corroborates.
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

  /// What a subscriber-only VOD's failure says.
  ///
  /// **A named constant because something else matches on it.**
  /// `AutoDownloadPolicy.isContentRestricted` counts failures carrying this
  /// exact summary to decide a whole channel is members-only, and a matcher
  /// comparing against an English sentence written somewhere else is one
  /// copy-edit away from silently never matching again. Naming it means the
  /// wording and the test for it cannot drift apart.
  ///
  /// **Twitch's signal and the CLI's signal are not the same string, and
  /// matching only on Twitch's meant this never fired in practice.**
  /// `docs/twitch-channel-api.md` §9.3 measured the manifest returning
  /// `{"error_code": "vod_manifest_restricted"}` — but that is what `usher`
  /// answers a direct request, and Oxbow never makes one. The CLI swallows
  /// the 403 inside `VideoDownloader.GetQualityPlaylist()` and rethrows a
  /// `NullReferenceException` carrying its own wording, so the only text that
  /// ever reaches this function is:
  ///
  /// ```
  /// System.NullReferenceException: Insufficient access to VOD, OAuth may be required.
  ///    at TwitchDownloaderCore.VideoDownloader.GetQualityPlaylist()
  /// ```
  ///
  /// Measured 2026-09-10 across 84 real failures on `middleditch` — the same
  /// channel §9.3 was measured against. Every one of them summarised through
  /// the fallback branch below instead of here, so
  /// `AutoDownloadPolicy.isContentRestricted` counted zero and a watch with
  /// automatic downloading on attempted the whole channel rather than
  /// stopping at three.
  ///
  /// The Twitch-side strings are kept as well: they cost nothing, and a
  /// future path that does read the manifest directly would produce them.
  ///
  /// **The CLI's phrasing is broader than this constant's name.**
  /// `GetQualityPlaylist` throws it for any playlist it cannot reach, which
  /// plausibly includes auth-gated cases that are not a membership. Matched
  /// here anyway, because the fact `isContentRestricted` needs is "this
  /// cannot be fetched without credentials Oxbow does not have", and that is
  /// true of all of them. Replacing the CLI's own sentence is also the better
  /// outcome for the reader: "OAuth may be required" dangles a remedy this
  /// app deliberately never offers, which is the same objection
  /// `AutoDownloadPolicy.Reason.contentRestricted` already raises against
  /// telling somebody to sign in.
  public static let subscriberOnlySummary = "This is a subscriber-only VOD."

  /// Known failures get a real sentence; everything else gets the innermost
  /// exception message. A stack trace is never the summary.
  private static func summarise(_ standardError: String) -> String {
    // The first is what the CLI actually prints and the only one of the three
    // ever observed in a real failure; the other two are what Twitch answers a
    // direct manifest request. See `subscriberOnlySummary` for why both are
    // here and why matching only the latter two meant this never fired.
    if standardError.contains("Insufficient access to VOD")
      || standardError.contains("vod_manifest_restricted")
      || standardError.contains("unauthorized_entitlements")
    {
      return subscriberOnlySummary
    }
    // Checked before the VOD case below, and matched on the longer string:
    // upstream throws a *different* sentence for a clip whose parent VOD is
    // gone ("Invalid VOD for clip, …") from the one it throws for a VOD that
    // is itself gone ("Invalid VOD, …"). The two are disjoint as written, so
    // the order is documentation rather than load-bearing — but the advice
    // differs, and a future edit that loosens either pattern to a shared
    // prefix must not silently collapse them into one.
    //
    // The clip's own video still downloads fine; only its chat cannot be
    // reconstructed, because chat lives on the broadcast the clip was cut
    // from (upstream: `clip.video == null || clip.videoOffsetSeconds == null`
    // in `ChatDownloader.InitChatRoot`). Saying so is the difference between
    // a user retrying forever and one who knows to ask for video alone.
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
      // FFmpeg prefixes every diagnostic with its component and a heap
      // address. The sentence after it is the useful part; the prefix is
      // noise in a one-line summary. Stripped here, before the `--->` check
      // below runs, so that selection sees the readable sentence.
      .map { line in
        line.replacing(/^\[[^\]]+ @ 0x[0-9a-f]+\]\s*/, with: "")
      }

    // .NET nests inner exceptions as `---> Type: message`. The last one is the
    // root cause and carries the most specific message. Strip the marker
    // before splitting on the colon: an exception with no message renders as
    // just `---> SomeException`, which has no ": " to split on, and the
    // marker must never survive into the user-facing sentence.
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
