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

  /// The most common real-world failure for a Twitch downloader.
  @Test func recognisesSubscriberOnlyVods() throws {
    let stderr = "Unhandled exception. System.Exception: vod_manifest_restricted"
    let failure = try #require(interpret(.exited(134), stderr, artifactExists: false))
    #expect(failure.summary == "This is a subscriber-only VOD.")
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
