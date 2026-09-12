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

  /// A clip whose parent VOD is gone. Upstream checks `clip.video == null ||
  /// clip.videoOffsetSeconds == null` and throws with a *different* sentence
  /// from the VOD case above — "Invalid VOD **for clip**, …" — so the VOD
  /// check does not cover it, and without its own case the summary is
  /// upstream's internal diagnostic, question mark and all.
  ///
  /// Real captured stderr, from `chatdownload --id
  /// AdorableStylishPotatoPlanking-5UAS4GFYHTkDW4xX`.
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

  /// The clip sentence must not swallow the VOD one: they are different
  /// failures with different advice, and `contains` on the shorter string
  /// would match both if either check were written loosely.
  @Test func keepsTheClipAndVodSentencesDistinct() throws {
    let vod = try #require(interpret(
      .signalled(SIGABRT),
      "---> System.NullReferenceException: Invalid VOD, deleted/expired VOD possibly?",
      artifactExists: false))
    #expect(vod.summary == "This VOD no longer exists or has expired.")
  }

  /// The most common real-world failure for a Twitch downloader.
  ///
  /// **This fixture is synthetic and that mattered.** `vod_manifest_restricted`
  /// is what `usher` answers a direct manifest request — which Oxbow never
  /// makes — so this test passed for months while the case it exists to cover
  /// never matched in production. `recognisesTheCLIsOwnSubscriberOnlyWording`
  /// below is the measured one. Kept because a future path that does read the
  /// manifest itself would produce this text.
  @Test func recognisesSubscriberOnlyVods() throws {
    let stderr = "Unhandled exception. System.Exception: vod_manifest_restricted"
    let failure = try #require(interpret(.exited(134), stderr, artifactExists: false))
    #expect(failure.summary == "This is a subscriber-only VOD.")
  }

  /// Captured verbatim from one of 84 real failures on `middleditch`,
  /// 2026-09-10, helper 1.56.5 — the channel `docs/twitch-channel-api.md`
  /// §9.3 was itself measured against.
  ///
  /// The CLI swallows the manifest's 403 and rethrows its own wording from
  /// `GetQualityPlaylist()`, so none of the Twitch-side error codes ever reach
  /// this function. Before this matched, every one of those 84 summarised
  /// through the unknown-error fallback, `AutoDownloadPolicy
  /// .isContentRestricted` counted zero, and a watch with automatic
  /// downloading on attempted the entire channel instead of stopping at three.
  ///
  /// Note the exit status: SIGABRT, not a nonzero exit. Upstream's `Main`
  /// returns void and an unhandled exception aborts, which is exactly what
  /// this type's own header says about exit codes corroborating rather than
  /// deciding.
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

  /// The half that makes the demotion work: the summary is not merely
  /// readable, it is the exact string `AutoDownloadPolicy` counts.
  ///
  /// Asserted against the constant *and* against the fallback it used to take,
  /// because "produces a sensible sentence" was already true of the broken
  /// behaviour — that is precisely why nobody noticed.
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

  /// `waitFailed` means we know nothing about how the process ended — it must
  /// never be reported as success, even if a stale artifact happens to exist
  /// from a previous run. A killed download must never read as a success.
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
