import Foundation
import Testing
@testable import OxbowKit

@Suite("Process spawning", .serialized)
struct SpawnTests {

  /// Creates a temporary executable fixture; callers must remove its directory in defer.
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

  /// Block SIGCHLD in the parent to prove spawn resets inherited masks. Otherwise CoreCLR can
  /// hang forever waiting for its exited FFmpeg child.
  @Test func spawnedChildrenDoNotInheritABlockedSignalMask() throws {
    var blocked = sigset_t()
    sigemptyset(&blocked)
    sigaddset(&blocked, SIGCHLD)
    var previous = sigset_t()
    pthread_sigmask(SIG_BLOCK, &blocked, &previous)
    defer { pthread_sigmask(SIG_SETMASK, &previous, nil) }

    // Use Python's `pthread_sigmask` to inspect the inherited mask without changing it.
    let (url, directory) = try script(
      #"exec /usr/bin/env python3 -c 'import signal; print(sorted(signal.pthread_sigmask(signal.SIG_BLOCK, [])))'"#)
    defer { try? FileManager.default.removeItem(at: directory) }

    let spawned = try ProcessSpawner.spawn(executable: url, arguments: [], workingDirectory: directory)
    let output = String(decoding: spawned.stdout.readDataToEndOfFile(), as: UTF8.self)
    _ = ProcessSpawner.wait(spawned.pid)

    #expect(!output.contains("\(SIGCHLD)"), "child inherited a blocked SIGCHLD; output was: \(output)")
    #expect(output.contains("[]"), "child inherited a non-empty signal mask: \(output)")
  }

  @Test func capturesStdoutAndExitCode() throws {
    let (url, directory) = try script("echo hello; exit 3")
    defer { try? FileManager.default.removeItem(at: directory) }
    let spawned = try ProcessSpawner.spawn(executable: url, arguments: [], workingDirectory: directory)

    let output = String(decoding: spawned.stdout.readDataToEndOfFile(), as: UTF8.self)
    let status = ProcessSpawner.wait(spawned.pid)

    #expect(output.trimmingCharacters(in: .whitespacesAndNewlines) == "hello")
    #expect(status == .exited(3))
  }

  @Test func distinguishesASignalFromAnExitCode() throws {
    let (url, directory) = try script("kill -9 $$")
    defer { try? FileManager.default.removeItem(at: directory) }
    let spawned = try ProcessSpawner.spawn(executable: url, arguments: [], workingDirectory: directory)
    #expect(ProcessSpawner.wait(spawned.pid) == .signalled(SIGKILL))
  }

  /// Track exactly shell and background sleep. Builtin `wait` avoids introducing an untracked
  /// third process that could leak despite passing assertions.
  @Test func killingTheGroupAlsoKillsGrandchildren() throws {
    let (url, directory) = try script("""
      sleep 300 &
      CHILD=$!
      echo $CHILD
      wait $CHILD
      """)
    defer { try? FileManager.default.removeItem(at: directory) }
    let spawned = try ProcessSpawner.spawn(executable: url, arguments: [], workingDirectory: directory)

    // Bound the wait for the grandchild PID so a failed fixture cannot hang the suite.
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

  /// Reject PID zero, which would signal our own process group.
  @Test func signalOnPidZeroIsANoOp() throws {
    let (url, directory) = try script("sleep 300")
    defer { try? FileManager.default.removeItem(at: directory) }
    let spawned = try ProcessSpawner.spawn(executable: url, arguments: [], workingDirectory: directory)
    defer {
      ProcessSpawner.signal(SIGKILL, toGroupOf: spawned.pid)
      _ = ProcessSpawner.wait(spawned.pid)
    }

    let result = ProcessSpawner.signal(SIGKILL, toGroupOf: 0)

    #expect(result == -1)
    #expect(isAlive(spawned.pid), "signal(toGroupOf: 0) must not touch any real process group")
  }

  /// Write beyond pipe capacity to verify concurrent draining avoids child deadlock.
  @Test func drainingStdoutAndStderrConcurrentlyAvoidsDeadlock() async throws {
    let (url, directory) = try script("""
      yes x | head -c 100000 1>&2
      echo done
      """)
    defer { try? FileManager.default.removeItem(at: directory) }
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
