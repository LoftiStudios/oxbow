import Foundation
import Testing
@testable import OxbowKit

@Suite("Process spawning", .serialized)
struct SpawnTests {

  /// Writes an executable shell script into a fresh temp directory.
  private func script(_ body: String) throws -> (url: URL, directory: URL) {
    let directory = URL(filePath: NSTemporaryDirectory())
      .appending(path: "oxbow-spawn-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = directory.appending(path: "fixture.sh")
    try "#!/bin/sh\n\(body)\n".write(to: url, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    return (url, directory)
  }

  private func isAlive(_ pid: pid_t) -> Bool { kill(pid, 0) == 0 }

  @Test func capturesStdoutAndExitCode() throws {
    let (url, directory) = try script("echo hello; exit 3")
    let spawned = try ProcessSpawner.spawn(executable: url, arguments: [], workingDirectory: directory)

    let output = String(decoding: spawned.stdout.readDataToEndOfFile(), as: UTF8.self)
    let status = ProcessSpawner.wait(spawned.pid)

    #expect(output.trimmingCharacters(in: .whitespacesAndNewlines) == "hello")
    #expect(status == .exited(3))
  }

  @Test func distinguishesASignalFromAnExitCode() throws {
    let (url, directory) = try script("kill -9 $$")
    let spawned = try ProcessSpawner.spawn(executable: url, arguments: [], workingDirectory: directory)
    #expect(ProcessSpawner.wait(spawned.pid) == .signalled(SIGKILL))
  }

  /// THE test. A helper that spawns a grandchild must not leave it running when
  /// we cancel — that is the orphaned-FFmpeg bug, made automatic.
  ///
  /// The fixture must spawn exactly two processes — the shell and the
  /// backgrounded sleep — so every process in the group is known to and
  /// asserted on by the test. `wait` is a shell builtin and forks nothing, so
  /// waiting on the backgrounded sleep (rather than the shell running a
  /// second `sleep 300` in its own foreground) keeps the group at exactly
  /// {shell, grandchild}. A shell running its own separate foreground sleep
  /// would be a third, untracked process that the group kill might not
  /// reliably reach before the test's assertions run — passing the test
  /// while still leaking a process.
  @Test func killingTheGroupAlsoKillsGrandchildren() throws {
    let (url, directory) = try script("""
      sleep 300 &
      CHILD=$!
      echo $CHILD
      wait $CHILD
      """)
    let spawned = try ProcessSpawner.spawn(executable: url, arguments: [], workingDirectory: directory)

    // First line of stdout is the grandchild's pid. availableData returns
    // immediately (possibly empty) rather than blocking, so an un-bounded
    // loop here would busy-spin forever if the fixture died before printing
    // anything — wedging CI instead of failing the test. Cap it with a
    // deadline and fail explicitly on expiry.
    var buffer = Data()
    let deadline = Date().addingTimeInterval(5)
    while !buffer.contains(UInt8(ascii: "\n")) {
      guard Date() < deadline else {
        Issue.record("Timed out waiting for the grandchild pid on stdout")
        return
      }
      let chunk = spawned.stdout.availableData
      if chunk.isEmpty {
        usleep(5_000)
      } else {
        buffer.append(chunk)
      }
    }
    let grandchildString = String(decoding: buffer, as: UTF8.self)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    let grandchild = try #require(pid_t(grandchildString))

    #expect(isAlive(spawned.pid))
    #expect(isAlive(grandchild))

    ProcessSpawner.signal(SIGKILL, toGroupOf: spawned.pid)
    _ = ProcessSpawner.wait(spawned.pid)

    // Give the kernel a moment to reap both members of the group.
    for _ in 0..<50 where isAlive(spawned.pid) || isAlive(grandchild) { usleep(20_000) }

    #expect(!isAlive(spawned.pid), "the shell itself would have been orphaned here")
    #expect(!isAlive(grandchild), "FFmpeg would have been orphaned here")
  }

  @Test func reportsSpawnFailureForAMissingExecutable() {
    #expect(throws: SpawnError.self) {
      try ProcessSpawner.spawn(
        executable: URL(filePath: "/nonexistent/binary"),
        arguments: [],
        workingDirectory: URL(filePath: NSTemporaryDirectory()))
    }
  }

  /// Finding 2: pid 0 means "my own process group" to `kill`, which for the
  /// host app would mean signalling Oxbow itself and everything launched
  /// alongside it. This must be refused rather than forwarded.
  @Test func signalOnPidZeroIsANoOp() throws {
    let (url, directory) = try script("sleep 300")
    let spawned = try ProcessSpawner.spawn(executable: url, arguments: [], workingDirectory: directory)
    defer {
      ProcessSpawner.signal(SIGKILL, toGroupOf: spawned.pid)
      _ = ProcessSpawner.wait(spawned.pid)
    }

    let result = ProcessSpawner.signal(SIGKILL, toGroupOf: 0)

    #expect(result == -1)
    #expect(isAlive(spawned.pid), "signal(toGroupOf: 0) must not touch any real process group")
  }

  /// Finding 3 regression test. macOS pipe buffers are 16 KB (growing to
  /// 64 KB); a child that writes more than that to a stream nobody is
  /// draining blocks in write(2) and never exits. This locks in that
  /// draining stdout and stderr concurrently avoids the deadlock — the
  /// pattern Task 11 already uses via two detached tasks.
  @Test func drainingStdoutAndStderrConcurrentlyAvoidsDeadlock() async throws {
    let (url, directory) = try script("""
      yes x | head -c 100000 1>&2
      echo done
      """)
    let spawned = try ProcessSpawner.spawn(executable: url, arguments: [], workingDirectory: directory)

    async let stdoutData = Task.detached { spawned.stdout.readDataToEndOfFile() }.value
    async let stderrData = Task.detached { spawned.stderr.readDataToEndOfFile() }.value

    let (out, err) = await (stdoutData, stderrData)
    let status = ProcessSpawner.wait(spawned.pid)

    #expect(String(decoding: out, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) == "done")
    #expect(err.count == 100_000)
    #expect(status == .exited(0))
  }
}
