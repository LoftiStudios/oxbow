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
  }

  private(set) var lastLaunch: Launch?
  private let behaviour: Behaviour

  init(_ behaviour: Behaviour) { self.behaviour = behaviour }

  func run(
    _ launch: Launch,
    onOutput: @escaping @Sendable (ParsedLine) async -> Void)
    async throws -> RunResult
  {
    lastLaunch = launch

    switch behaviour {
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

  func cancel() async {}
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
      (error as? VideoInfoFetchError) == .unparseableOutput
    }
  }

  @Test func buildsTheExpectedArgv() async throws {
    let fake = FakeInfoHelper(.succeeds(stdout: try fixture()))

    _ = try await VideoInfoFetcher.fetch(id: "241234567", helper: helperPath, process: fake)

    let launch = try #require(await fake.lastLaunch)
    #expect(launch.arguments == ["info", "--banner=false", "--id", "241234567", "--format", "Raw"])
    #expect(launch.executable == helperPath)
  }
}
