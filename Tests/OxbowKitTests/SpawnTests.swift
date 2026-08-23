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
  @Test func killingTheGroupAlsoKillsGrandchildren() throws {
    let (url, directory) = try script("""
      sleep 300 &
      echo $!
      sleep 300
      """)
    let spawned = try ProcessSpawner.spawn(executable: url, arguments: [], workingDirectory: directory)

    // First line of stdout is the grandchild's pid.
    var buffer = Data()
    while !buffer.contains(UInt8(ascii: "\n")) {
      buffer.append(spawned.stdout.availableData)
    }
    let grandchild = pid_t(String(decoding: buffer, as: UTF8.self)
      .trimmingCharacters(in: .whitespacesAndNewlines))!

    #expect(isAlive(spawned.pid))
    #expect(isAlive(grandchild))

    ProcessSpawner.signal(SIGKILL, toGroupOf: spawned.pid)
    _ = ProcessSpawner.wait(spawned.pid)

    // Give the kernel a moment to reap.
    for _ in 0..<50 where isAlive(grandchild) { usleep(20_000) }

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
}
