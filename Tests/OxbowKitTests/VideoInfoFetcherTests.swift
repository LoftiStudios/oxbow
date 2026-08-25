import Foundation
import Testing
@testable import OxbowKit

/// A helper double for `VideoInfoFetcher` that captures the `Launch` it was
/// given and replays a chosen stdout through the **real** `StatusLineParser`.
///
/// Routing through the real parser — rather than calling `onOutput` with
/// hand-built `.log`/`.ffmpeg` cases directly — is deliberate: the fixture's
/// leading `[STATUS] - Fetching Video Info [1/1]` line really does classify
/// as `.status`, and every JSON/m3u8 line after it really does classify as
/// `.log` (nothing in `info --format Raw`'s body matches a known preamble).
/// A fetcher that only listened to `.status`, or that dropped anything after
/// the first line, fails against this fake exactly as it would against a
/// real helper.
private actor FakeInfoHelper: HelperProcessing {
  enum Behaviour: Sendable {
    case succeeds(stdout: String)
    case fails(exitCode: Int32, stderr: String)
    /// Blocks inside `run` until `cancel()` arrives, then reports as killed —
    /// what a real `info` invocation does, since it observes nothing about
    /// the task awaiting it.
    case hangsUntilCancelled
  }

  private(set) var lastLaunch: Launch?
  private(set) var isRunning = false
  private(set) var wasCancelled = false
  private let behaviour: Behaviour
  private var cancelContinuation: CheckedContinuation<Void, Never>?

  init(_ behaviour: Behaviour) { self.behaviour = behaviour }

  func run(
    _ launch: Launch,
    onOutput: @escaping @Sendable (ParsedLine) async -> Void)
    async throws -> RunResult
  {
    lastLaunch = launch
    isRunning = true
    defer { isRunning = false }

    switch behaviour {
    case .hangsUntilCancelled:
      if !wasCancelled {
        await withCheckedContinuation { cancelContinuation = $0 }
      }
      // SIGTERM: 15.
      return RunResult(status: .signalled(15), standardError: "")

    case .succeeds(let stdout):
      var parser = StatusLineParser()
      for line in parser.consume(Array(stdout.utf8)) { await onOutput(line) }
      if let tail = parser.finish() { await onOutput(tail) }
      return RunResult(status: .exited(0), standardError: "")

    case .fails(let exitCode, let stderr):
      // A helper that dies still leaves a fully-formed, parseable payload on
      // stdout impossible in practice, but this fake sends none at all — the
      // point is to prove the exit status is checked on its own, not only
      // inferred from whether parsing succeeded.
      return RunResult(status: .exited(exitCode), standardError: stderr)
    }
  }

  func cancel() async {
    wasCancelled = true
    cancelContinuation?.resume()
    cancelContinuation = nil
  }
}

@Suite("Video info fetcher")
struct VideoInfoFetcherTests {
  private let helperPath = URL(fileURLWithPath: "/opt/oxbow/TwitchDownloaderCLI")

  private func fixture() throws -> String {
    String(decoding: try Fixture.bytes("info-vod-raw.stdout"), as: UTF8.self)
  }

  @Test func parsesTheRealVideoInfoFromTheFixture() async throws {
    let fake = FakeInfoHelper(.succeeds(stdout: try fixture()))

    let info = try await VideoInfoFetcher.fetch(id: "2412345678", helper: helperPath, process: fake)

    // Values pinned to the captured fixture (see VideoInfoTests), not just
    // "non-nil" — a fetcher that fed the parser an empty or wrong string
    // (e.g. only the `.status` banner) would fail these.
    #expect(info.streamer == "LeighXP")
    #expect(info.qualities.map(\.name) == ["1080p60", "720p60", "480p30", "360p30", "160p30"])
  }

  /// The clip payload is one JSON object with **no trailing newline** — the
  /// CLI's `HandleClipRaw` serializes and stops — so the whole thing only ever
  /// reaches the parser through `StatusLineParser.finish()`. A fetcher that
  /// listened to `consume` alone would see the `[STATUS]` banner and nothing
  /// else, which is why this goes through the real parser rather than calling
  /// `VideoInfo.parse` on the fixture directly.
  @Test func parsesTheRealClipInfoFromTheFixture() async throws {
    let stdout = String(decoding: try Fixture.bytes("info-clip-raw.stdout"), as: UTF8.self)
    #expect(!stdout.hasSuffix("\n"))
    let fake = FakeInfoHelper(.succeeds(stdout: stdout))

    let info = try await VideoInfoFetcher.fetch(
      id: "AbstemiousSillyPuppyBCouch-x_zVHj6Yc6UvUVuu", helper: helperPath, process: fake)

    #expect(info.streamer == "xQc")
    #expect(info.title == "Me on stream")
    #expect(info.qualities.first?.name == "1080p60-1")
  }

  @Test func throwsWhenTheHelperExitsNonZero() async throws {
    let fake = FakeInfoHelper(.fails(exitCode: 134, stderr: "boom"))

    await #expect {
      _ = try await VideoInfoFetcher.fetch(id: "123", helper: helperPath, process: fake)
    } throws: { error in
      guard case .helperFailed(let status, let standardError) = error as? VideoInfoFetchError else {
        return false
      }
      return status == .exited(134) && standardError == "boom"
    }
  }

  @Test func throwsWhenTheOutputDoesNotParse() async throws {
    // Exits cleanly, but nothing here is JSON: proves the failure is about
    // parseability, distinct from (and not just a rename of) the non-zero
    // exit case above.
    let fake = FakeInfoHelper(.succeeds(stdout: "[STATUS] - Fetching Video Info [1/1]\nnot json\n"))

    await #expect {
      _ = try await VideoInfoFetcher.fetch(id: "123", helper: helperPath, process: fake)
    } throws: { error in
      guard case .unparseableOutput = error as? VideoInfoFetchError else { return false }
      return true
    }
  }

  /// The snippet must contain something specific to *this* failure, not just
  /// be non-empty — a wrong implementation that attached a fixed placeholder
  /// string (e.g. `"unparseable"`) would satisfy an empty-string check but
  /// give a debugger nothing to work from.
  @Test func unparseableOutputErrorCarriesARecognizableSnippet() async throws {
    let fake = FakeInfoHelper(
      .succeeds(stdout: "[STATUS] - Fetching Video Info [1/1]\ndefinitely-not-json-2946\n"))

    await #expect {
      _ = try await VideoInfoFetcher.fetch(id: "123", helper: helperPath, process: fake)
    } throws: { error in
      guard case .unparseableOutput(let snippet) = error as? VideoInfoFetchError else { return false }
      return snippet.contains("definitely-not-json-2946")
    }
  }

  /// Pins the snippet's bound. Feeds output far larger than the limit and
  /// asserts the payload stays within it — so a future edit that drops the
  /// truncation can't silently let an unbounded payload back into the error.
  @Test func unparseableOutputSnippetStaysWithinItsBound() async throws {
    let huge = String(repeating: "z", count: VideoInfoFetcher.snippetLimit * 20)
    let fake = FakeInfoHelper(.succeeds(stdout: huge))

    await #expect {
      _ = try await VideoInfoFetcher.fetch(id: "123", helper: helperPath, process: fake)
    } throws: { error in
      guard case .unparseableOutput(let snippet) = error as? VideoInfoFetchError else { return false }
      // Some room over the raw limit for the truncation marker itself, but
      // nowhere close to `huge`'s size — the point being tested.
      return snippet.count <= VideoInfoFetcher.snippetLimit + 64 && snippet.count < huge.count
    }
  }

  /// Intake refetches on every keystroke and SwiftUI cancels the fetch it
  /// supersedes — but `HelperProcess.run` blocks on `waitpid` and observes
  /// nothing about the task awaiting it. Without an explicit cancellation
  /// handler, each superseded paste left a real `info` subprocess talking to
  /// Twitch until it finished, its result thrown away.
  @Test func cancellingTheFetchSignalsTheHelper() async throws {
    let fake = FakeInfoHelper(.hangsUntilCancelled)
    let task = Task {
      try await VideoInfoFetcher.fetch(id: "123", helper: helperPath, process: fake)
    }

    // The helper must actually be running before the cancellation is
    // meaningful; cancelling a task that has not reached `run` yet would pass
    // against an implementation that never signals at all.
    await Self.waitUntil("the helper is running") { await fake.isRunning }
    task.cancel()

    await #expect(throws: CancellationError.self) { try await task.value }
    #expect(await fake.wasCancelled)
  }

  /// And the caller sees a cancellation, not a helper failure — the sheet
  /// turns `.helperFailed` into "Oxbow could not read that video's details",
  /// which is the wrong thing to say to someone who simply kept typing.
  @Test func aCancelledFetchThrowsCancellationNotAHelperFailure() async throws {
    let fake = FakeInfoHelper(.hangsUntilCancelled)
    let task = Task {
      try await VideoInfoFetcher.fetch(id: "123", helper: helperPath, process: fake)
    }
    await Self.waitUntil("the helper is running") { await fake.isRunning }
    task.cancel()

    do {
      _ = try await task.value
      Issue.record("expected the cancelled fetch to throw")
    } catch {
      #expect(error is CancellationError)
      #expect(!(error is VideoInfoFetchError))
    }
  }

  /// Bounded, so a fetcher that never starts the helper fails the test rather
  /// than hanging it.
  private static func waitUntil(
    _ description: String,
    yields: Int = 10_000,
    _ condition: () async -> Bool)
    async
  {
    for _ in 0..<yields {
      if await condition() { return }
      await Task.yield()
    }
    Issue.record("timed out waiting until \(description)")
  }

  @Test func buildsTheExpectedArgv() async throws {
    let fake = FakeInfoHelper(.succeeds(stdout: try fixture()))

    _ = try await VideoInfoFetcher.fetch(id: "241234567", helper: helperPath, process: fake)

    let launch = try #require(await fake.lastLaunch)
    #expect(launch.arguments == ["info", "--banner=false", "--id", "241234567", "--format", "Raw"])
    #expect(launch.executable == helperPath)
  }
}
