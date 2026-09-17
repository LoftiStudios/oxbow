import Foundation
import Testing
@testable import OxbowKit

/// Replay stdout through the real parser so status banners and JSON/playlist logs are
/// classified as in production. Captures the invocation for wiring assertions.
private actor FakeInfoHelper: HelperProcessing {
  enum Behaviour: Sendable {
    case succeeds(stdout: String)
    case fails(exitCode: Int32, stderr: String)
    /// Waits for explicit cancellation, like the real subprocess.
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
      // No payload; verify abnormal exit independently of parsing.
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

    // Pin captured values so wrong-line forwarding cannot pass.
    #expect(info.streamer == "LeighXP")
    #expect(info.qualities.map(\.name) == ["1080p60", "720p60", "480p30", "360p30", "160p30"])
  }

  /// Clip JSON has no final newline and reaches consumers only through parser finish. Exercise
  /// the real incremental parser to catch a missing flush.
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
    // Clean exit with non-JSON output isolates parse failure.
    let fake = FakeInfoHelper(.succeeds(stdout: "[STATUS] - Fetching Video Info [1/1]\nnot json\n"))

    await #expect {
      _ = try await VideoInfoFetcher.fetch(id: "123", helper: helperPath, process: fake)
    } throws: { error in
      guard case .unparseableOutput = error as? VideoInfoFetchError else { return false }
      return true
    }
  }

  /// Require failure-specific snippet content, not just a nonempty placeholder.
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

  /// Oversized output must remain bounded in diagnostics.
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

  /// Task cancellation must reach the subprocess; otherwise superseded metadata fetches keep
  /// talking to Twitch.
  @Test func cancellingTheFetchSignalsTheHelper() async throws {
    let fake = FakeInfoHelper(.hangsUntilCancelled)
    let task = Task {
      try await VideoInfoFetcher.fetch(id: "123", helper: helperPath, process: fake)
    }

    // Wait until the helper runs so cancellation cannot pass without signalling it.
    await Self.waitUntil("the helper is running") { await fake.isRunning }
    task.cancel()

    await #expect(throws: CancellationError.self) { try await task.value }
    #expect(await fake.wasCancelled)
  }

  /// Report cancellation rather than a metadata failure while the user is typing.
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

  /// Retain the parsed payload lines for future metadata readers.
  @Test("fetchDetailed returns the raw payload alongside the info")
  func detailedCarriesThePayload() async throws {
    let payload = """
      {"data":{"video":{"title":"day 46","createdAt":"2026-09-01T12:00:00Z",\
      "lengthSeconds":10203,"owner":{"displayName":"WheelyF","login":"wheelyf"},\
      "thumbnailURLs":["https://cdn/a.jpg"]}}}
      {"data":{"video":{"id":"1","moments":{"edges":[]}}}}
      #EXTM3U
      #EXT-X-STREAM-INF:BANDWIDTH=6000000,RESOLUTION=1920x1080,STABLE-VARIANT-ID="1080p60"
      https://example/1080p60.m3u8
      """

    let fetched = try await VideoInfoFetcher.fetchDetailed(
      id: "2844787557",
      helper: helperPath,
      process: FakeInfoHelper(.succeeds(stdout: payload)))

    #expect(fetched.info.login == "wheelyf")
    #expect(fetched.payload == payload)
    // Keep moments despite no current consumer.
    #expect(fetched.payload.contains("moments"))
  }

  @Test("fetch still returns just the info")
  func fetchIsUnchanged() async throws {
    let payload = """
      {"data":{"video":{"title":"t","createdAt":"2026-09-01T12:00:00Z",\
      "lengthSeconds":60,"owner":{"displayName":"W"},"thumbnailURLs":[]}}}
      #EXTM3U
      """

    let info = try await VideoInfoFetcher.fetch(
      id: "1", helper: helperPath,
      process: FakeInfoHelper(.succeeds(stdout: payload)))

    #expect(info.title == "t")
  }
}
