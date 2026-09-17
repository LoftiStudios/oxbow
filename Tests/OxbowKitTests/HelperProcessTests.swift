import Foundation
import Testing
@testable import OxbowKit

@Suite("HelperProcess", .serialized)
struct HelperProcessTests {

  /// Creates an executable fixture. Caller must pair it with `defer { remove(launch) }` to
  /// remove its directory.
  private func script(_ body: String, dialect: OutputDialect = .helper) throws -> Launch {
    let directory = URL(filePath: NSTemporaryDirectory())
      .appending(path: "oxbow-helper-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = directory.appending(path: "fixture.sh")
    try "#!/bin/sh\n\(body)\n".write(to: url, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    return Launch(executable: url, arguments: [], workingDirectory: directory, dialect: dialect)
  }

  private func remove(_ launch: Launch) {
    try? FileManager.default.removeItem(at: launch.workingDirectory)
  }

  /// Progress must arrive incrementally, and `\r`-delimited output must be
  /// recovered exactly as it is from the real CLI.
  @Test func streamsParsedProgressWhileRunning() async throws {
    let launch = try script(#"printf '[STATUS] - Downloading 50%%\r[STATUS] - Downloading 100%% [1/1]\n'"#)
    defer { remove(launch) }

    let collected = CollectedOutput()
    let process = HelperProcess()
    let result = try await process.run(launch) { await collected.append($0) }

    let lines = await collected.lines
    #expect(result.status == .exited(0))
    #expect(lines.count == 2)
    if case .status(let last) = lines[1] {
      #expect(last.fraction == 1.0)
      #expect(last.index == 1)
    } else {
      Issue.record("expected a status line")
    }
  }

  @Test func capturesStandardErrorSeparately() async throws {
    let launch = try script("echo boom >&2; exit 134")
    defer { remove(launch) }
    let result = try await HelperProcess().run(launch) { _ in }

    #expect(result.status == .exited(134))
    #expect(result.standardError.contains("boom"))
  }

  /// Cancellation must reach a grandchild, and must not hang.
  @Test func cancellationTerminatesTheProcessGroup() async throws {
    let launch = try script("sleep 300 & sleep 300")
    defer { remove(launch) }
    let process = HelperProcess()

    let running = Task { try await process.run(launch) { _ in } }
    try await Task.sleep(for: .milliseconds(300))
    await process.cancel()

    let result = try await running.value
    #expect(result.status == .signalled(SIGTERM) || result.status == .signalled(SIGKILL))
  }

  /// Run more helpers than cores to detect cooperative-pool blocking that starves cancellation.
  /// Fixtures self-exit after about 15 seconds so a regression fails timing/status assertions
  /// instead of hanging indefinitely.
  @Test func cancellationIsDeliveredWhileEveryCoreRunsABlockedHelper() async throws {
    let width = ProcessInfo.processInfo.activeProcessorCount + 2
    var launches: [Launch] = []
    for _ in 0..<width { launches.append(try script("sleep 15")) }
    defer { for launch in launches { remove(launch) } }

    let processes = (0..<width).map { _ in HelperProcess() }
    let clock = ContinuousClock()
    let start = clock.now

    let results = try await withThrowingTaskGroup(of: RunResult.self) { group in
      for (process, launch) in zip(processes, launches) {
        group.addTask { try await process.run(launch) { _ in } }
      }
      try await Task.sleep(for: .milliseconds(500))
      // Cancel concurrently; serial two-second grace periods would let later fixtures exit
      // naturally.
      await withTaskGroup(of: Void.self) { cancels in
        for process in processes { cancels.addTask { await process.cancel() } }
      }
      var collected: [RunResult] = []
      for try await result in group { collected.append(result) }
      return collected
    }
    let elapsed = clock.now - start

    for result in results {
      #expect(result.status == .signalled(SIGTERM) || result.status == .signalled(SIGKILL))
    }
    #expect(elapsed < .seconds(10), "cancellations were starved until the fixtures exited on their own")
  }

  /// Pre-cancelled helpers must never spawn, even briefly.
  @Test func cancellingBeforeRunNeverStartsTheProcess() async throws {
    let launch = try script(#"touch "$(dirname "$0")/ran""#)
    defer { remove(launch) }
    let evidence = launch.workingDirectory.appending(path: "ran")

    let process = HelperProcess()
    await process.cancel()
    let result = try await process.run(launch) { _ in }

    #expect(result.status == .signalled(SIGKILL))
    #expect(
      !FileManager.default.fileExists(atPath: evidence.path),
      "a cancelled instance must not have run the helper")
  }

  /// Write beyond pipe capacity to prove both streams drain concurrently. A 30-second deadline
  /// cancels the whole fixture group so sequential-drain regressions fail rather than hang or
  /// leak children.
  @Test func drainsLargeStderrConcurrentlyWithStdout() async throws {
    let launch = try script(#"""
      (yes x | head -c 100000 1>&2) &
      BG=$!
      printf '[STATUS] - Downloading 50%%\r[STATUS] - Downloading 100%% [1/1]\n'
      wait $BG
      """#)
    defer { remove(launch) }

    let collected = CollectedOutput()
    let process = HelperProcess()

    let result: RunResult? = try await withThrowingTaskGroup(of: RunResult?.self) { group in
      group.addTask {
        try await process.run(launch) { await collected.append($0) }
      }
      group.addTask {
        try await Task.sleep(for: .seconds(30))
        return nil
      }

      // `run` always yields a non-nil RunResult, so a nil result here can
      // only be the deadline task winning the race.
      let outcome = try await group.next() ?? nil
      if outcome == nil {
        Issue.record("""
          drainsLargeStderrConcurrentlyWithStdout exceeded its 30s deadline — stdout/stderr \
          draining may have regressed to sequential
          """)
        await process.cancel()
      }
      group.cancelAll()
      return outcome
    }

    guard let result else { return }

    let lines = await collected.lines
    #expect(result.status == .exited(0))
    #expect(result.standardError.count == 100_000)
    #expect(lines.count == 2)
    if case .status(let last) = lines[1] {
      #expect(last.fraction == 1.0)
    } else {
      Issue.record("expected a status line")
    }
  }

  /// The fixture waits for a sentinel created by its output callback, proving delivery occurs
  /// before exit. A bounded five-second poll makes deferred parsing fail timing checks without
  /// hanging.
  @Test func deliversOutputWhileTheProcessIsStillRunning() async throws {
    let launch = try script(#"""
      DIR="$(dirname "$0")"
      printf '[STATUS] - Downloading 50%% [1/2]\n'
      i=0
      while [ ! -f "$DIR/sentinel" ] && [ $i -lt 100 ]; do
        sleep 0.05
        i=$((i+1))
      done
      """#)
    defer { remove(launch) }
    let sentinel = launch.workingDirectory.appending(path: "sentinel")

    let clock = ContinuousClock()
    let start = clock.now
    let result = try await HelperProcess().run(launch) { _ in
      try? Data().write(to: sentinel)
    }
    let elapsed = clock.now - start

    #expect(result.status == .exited(0))
    if elapsed > .seconds(2) {
      Issue.record("first onOutput did not arrive before the fixture exited (elapsed \(elapsed))")
    }
  }

  /// The dialect, not the content, decides which parser reads stdout.
  @Test func theFFmpegDialectParsesProgressBlocks() async throws {
    let launch = try script(
      #"printf 'out_time_us=5000000\nspeed=2.0x\nprogress=continue\n'"#,
      dialect: .ffmpeg(duration: .seconds(10)))
    defer { remove(launch) }

    let collected = CollectedOutput()
    let result = try await HelperProcess().run(launch) { await collected.append($0) }
    let lines = await collected.lines

    #expect(result.status == .exited(0))
    // One status line for the completed block — not three lines of text.
    #expect(lines.count == 1)
    guard case .status(let progress) = lines[0] else {
      Issue.record("expected a status line"); return
    }
    #expect(progress.fraction == 0.5)
  }

  /// The same bytes are plain text under the CLI dialect, verifying parser selection.
  @Test func theHelperDialectDoesNotParseFFmpegProgress() async throws {
    let launch = try script(#"printf 'out_time_us=5000000\nprogress=continue\n'"#)
    defer { remove(launch) }

    let collected = CollectedOutput()
    _ = try await HelperProcess().run(launch) { await collected.append($0) }
    let lines = await collected.lines

    #expect(!lines.isEmpty)
    #expect(lines.allSatisfy { if case .log = $0 { true } else { false } })
  }
}
