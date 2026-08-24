import Foundation
import Testing
@testable import OxbowKit

@Suite("HelperProcess", .serialized)
struct HelperProcessTests {

  /// Writes an executable shell fixture into its own temp directory.
  ///
  /// - Important: the caller owns that directory. Pair every call with
  ///   `defer { remove(launch) }`, or the suite strews one directory per test
  ///   through the temp dir on every run.
  private func script(_ body: String) throws -> Launch {
    let directory = URL(filePath: NSTemporaryDirectory())
      .appending(path: "oxbow-helper-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = directory.appending(path: "fixture.sh")
    try "#!/bin/sh\n\(body)\n".write(to: url, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    return Launch(executable: url, arguments: [], workingDirectory: directory)
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

  /// An instance cancelled before `run` must not spawn anything at all.
  /// Spawning and then immediately killing still starts a real CLI process,
  /// which reaches the network before it dies.
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

  /// Regression guard for concurrent draining. A fixture that writes well
  /// past the 16–64 KB pipe buffer to stderr, while also writing status
  /// lines to stdout, cannot complete unless both streams are drained at
  /// the same time: if stderr is drained only after stdout reaches EOF (or
  /// vice versa), the writer on the undrained side blocks in `write(2)`
  /// forever, the process never exits, and `run` never returns. Every
  /// fixture elsewhere in this file writes only a few dozen bytes, so none
  /// of them would catch a regression in `run`'s own await ordering — this
  /// one is sized specifically to.
  ///
  /// Bounded by a 30s deadline raced against `run`. Reproducing the
  /// sequential-draining bug during review hung this exact test
  /// indefinitely (25s+, required a manual kill) — a wedged CI job that
  /// never produces a red result is worse than a clean failure, so a
  /// regression here must fail loudly instead of hanging. If the deadline
  /// wins, `process.cancel()` also kills the fixture's `yes`/`head` pair,
  /// which otherwise survive the hang (confirmed via `ps` during that same
  /// reproduction).
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

  /// Regression guard for incrementality: `streamsParsedProgressWhileRunning`
  /// only inspects output after `run` has already returned, so it cannot
  /// tell "parsed as it arrived" apart from "read everything, then parsed
  /// it all at the end". This test can, by making the fixture's own
  /// progress depend on the callback having already fired: the fixture
  /// emits one status line, then polls for a sentinel file that only this
  /// test's `onOutput` closure creates — so the sentinel can only appear if
  /// the line was parsed and delivered while the process was still
  /// running.
  ///
  /// The fixture's poll loop is itself bounded (100 x 50ms = ~5s), so if
  /// output is only parsed after exit — meaning the sentinel is created too
  /// late to matter — the fixture still exits on its own and nothing is
  /// left running. The elapsed-time assertion below fails loudly on that
  /// slow path instead of the test wedging.
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
}
