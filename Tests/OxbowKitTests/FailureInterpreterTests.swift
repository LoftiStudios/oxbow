import Foundation
import Testing
@testable import OxbowKit

@Suite("Failure interpretation")
struct FailureInterpreterTests {

  private func interpret(
    _ status: ProcessExitStatus,
    _ stderr: String = "",
    artifactExists: Bool = true)
    -> StepFailure?
  {
    FailureInterpreter.interpret(
      exitStatus: status, standardError: stderr, artifactExists: artifactExists)
  }

  /// Success is an artifact, not an exit code. The CLI's Main returns void, so
  /// a zero exit proves nothing on its own.
  @Test func successRequiresAnArtifactNotJustAZeroExit() {
    #expect(interpret(.exited(0), artifactExists: true) == nil)
    #expect(interpret(.exited(0), artifactExists: false)?.kind == .noArtifact)
  }

  @Test func distinguishesACrashFromAnExitCode() {
    #expect(interpret(.signalled(SIGSEGV), artifactExists: false)?.kind == .signalled(SIGSEGV))
    #expect(interpret(.exited(134), artifactExists: false)?.kind == .exited(code: 134))
  }

  /// Real captured stderr. The useful sentence is buried in a stack trace.
  @Test func extractsTheInnermostExceptionMessage() throws {
    let stderr = """
      Unhandled exception. System.AggregateException: One or more errors occurred. (Invalid VOD, deleted/expired VOD possibly?)
       ---> System.NullReferenceException: Invalid VOD, deleted/expired VOD possibly?
         at TwitchDownloaderCore.VideoDownloader.DownloadAsyncImpl(...)
      """
    let failure = try #require(interpret(.exited(134), stderr, artifactExists: false))
    #expect(failure.summary == "This VOD no longer exists or has expired.")
    #expect(failure.detail == stderr, "the full trace is kept for bug reports")
  }

  /// Captured clip-chat failure names an expired parent VOD differently from the VOD failure;
  /// match both separately.
  @Test func recognisesAClipWhoseParentVodIsGone() throws {
    let stderr = """
      Unhandled exception. System.AggregateException: One or more errors occurred. (Invalid VOD for clip, deleted/expired VOD possibly?)
       ---> System.NullReferenceException: Invalid VOD for clip, deleted/expired VOD possibly?
         at TwitchDownloaderCore.ChatDownloader.InitChatRoot(DownloadType downloadType)
      """
    let failure = try #require(interpret(.signalled(SIGABRT), stderr, artifactExists: false))
    #expect(failure.summary == """
      This clip's original broadcast is no longer on Twitch, so its chat \
      cannot be downloaded.
      """)
    #expect(failure.detail == stderr, "the full trace is kept for bug reports")
  }

  /// Clip and VOD failures require different advice; neither matcher may swallow the other.
  @Test func keepsTheClipAndVodSentencesDistinct() throws {
    let vod = try #require(interpret(
      .signalled(SIGABRT),
      "---> System.NullReferenceException: Invalid VOD, deleted/expired VOD possibly?",
      artifactExists: false))
    #expect(vod.summary == "This VOD no longer exists or has expired.")
  }

  /// Synthetic manifest error, retained for possible direct-manifest callers. The CLI rethrows
  /// different text, covered below.
  @Test func recognisesSubscriberOnlyVods() throws {
    let stderr = "Unhandled exception. System.Exception: vod_manifest_restricted"
    let failure = try #require(interpret(.exited(134), stderr, artifactExists: false))
    #expect(failure.summary == "This is a subscriber-only VOD.")
  }

  /// Captured helper 1.56.5 subscriber-only failure. The CLI replaces manifest 403 with its own
  /// wording and aborts via SIGABRT; Twitch error codes never reach this parser.
  @Test func recognisesTheCLIsOwnSubscriberOnlyWording() throws {
    let stderr = """
      Unhandled exception. System.AggregateException: One or more errors occurred. \
      (Insufficient access to VOD, OAuth may be required.)
       ---> System.NullReferenceException: Insufficient access to VOD, OAuth may be required.
         at TwitchDownloaderCore.VideoDownloader.GetQualityPlaylist()
         at TwitchDownloaderCore.VideoDownloader.DownloadAsyncImpl(FileInfo outputFileInfo, FileStream outputFs, CancellationToken cancellationToken)
         at TwitchDownloaderCore.VideoDownloader.DownloadAsync(CancellationToken cancellationToken)
         --- End of inner exception stack trace ---
         at TwitchDownloaderCLI.Program.Main(String[] args)
      """
    let failure = try #require(interpret(.signalled(SIGABRT), stderr, artifactExists: false))
    #expect(failure.summary == FailureInterpreter.subscriberOnlySummary)
  }

  /// Pin the exact restriction summary consumed by auto-download policy, not just readable
  /// wording.
  @Test func theCLIsWordingIsNotLeftToTheUnknownErrorFallback() throws {
    let stderr =
      "---> System.NullReferenceException: Insufficient access to VOD, OAuth may be required."
    let failure = try #require(interpret(.signalled(SIGABRT), stderr, artifactExists: false))
    #expect(failure.summary != "Insufficient access to VOD, OAuth may be required.")
    #expect(failure.summary == FailureInterpreter.subscriberOnlySummary)
  }

  @Test func fallsBackToTheExtractedSentenceForUnknownErrors() throws {
    let stderr = """
      Unhandled exception. System.AggregateException: One or more errors occurred. (Disk full)
       ---> System.IOException: No space left on device
         at Something(...)
      """
    let failure = try #require(interpret(.exited(134), stderr, artifactExists: false))
    #expect(failure.summary == "No space left on device")
  }

  /// A stack trace must never become the user-facing sentence.
  @Test func neverSurfacesAStackTraceAsTheSummary() throws {
    let stderr = "   at TwitchDownloaderCore.VideoDownloader.DownloadAsyncImpl(...)"
    let failure = try #require(interpret(.exited(1), stderr, artifactExists: false))
    #expect(!failure.summary.contains("   at "))
  }

  /// An inner exception with no message has no ": " to split on. The `--->`
  /// marker must never survive into the user-facing summary regardless.
  @Test func stripsTheMarkerWhenTheInnermostExceptionHasNoMessage() throws {
    let stderr = """
      Unhandled exception. System.AggregateException: One or more errors occurred.
       ---> System.NullReferenceException
         at Something(...)
      """
    let failure = try #require(interpret(.exited(134), stderr, artifactExists: false))
    #expect(failure.summary == "System.NullReferenceException")
    #expect(!failure.summary.contains("--->"))
  }

  /// Unknown wait status cannot count as success even with a stale artifact.
  @Test func waitFailedIsAlwaysAFailureNeverSuccess() throws {
    let failure = try #require(interpret(.waitFailed(errno: ECHILD), artifactExists: true))
    #expect(failure.kind == StepFailure.Kind.waitFailed(errno: ECHILD))
  }

  /// Real FFmpeg stderr. The address prefix is noise; the sentence is not.
  @Test func stripsFFmpegsComponentPrefixFromTheSummary() throws {
    let stderr = """
      [Parsed_hstack_3 @ 0x87101cd80] Input 1 height 900 does not match input 0 height 1080.
      [Parsed_hstack_3 @ 0x87101cd80] Failed to configure output pad on Parsed_hstack_3
      """
    let failure = try #require(FailureInterpreter.interpret(
      exitStatus: .exited(234), standardError: stderr, artifactExists: false))
    #expect(failure.summary == "Input 1 height 900 does not match input 0 height 1080.")
  }

  @Test func doesNotCallEveryStepADownload() throws {
    let failure = try #require(FailureInterpreter.interpret(
      exitStatus: .exited(1), standardError: "", artifactExists: false))
    #expect(!failure.summary.contains("download tool"))
  }
}
