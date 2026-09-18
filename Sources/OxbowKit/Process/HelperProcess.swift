import Darwin
import Foundation

/// Runs one CLI invocation. Cancellation sends SIGTERM for FFmpeg to close output, then
/// SIGKILL; the CLI has no cooperative cancellation path. Stdout, stderr, and waitpid each use
/// a dedicated blocking thread so cancellation cannot be starved by the cooperative pool.
/// Instances are single-use: cancellation is permanent, and a cancelled instance never spawns a
/// process.
public actor HelperProcess {
  private var spawned: Spawn?
  private var isCancelled = false

  public init() {}

  public func run(
    _ launch: Launch,
    onOutput: @escaping @Sendable (ParsedLine) async -> Void)
    async throws -> RunResult
  {
    // Check before spawning so a cancelled fetch cannot briefly launch a helper and contact
    // Twitch.
    if isCancelled {
      return RunResult(status: .signalled(SIGKILL), standardError: "")
    }

    let spawned = try ProcessSpawner.spawn(
      executable: launch.executable,
      arguments: launch.arguments,
      workingDirectory: launch.workingDirectory)
    self.spawned = spawned

    if isCancelled {
      ProcessSpawner.signal(SIGKILL, toGroupOf: spawned.pid)
    }

    let stdoutHandle = spawned.stdout
    let stderrHandle = spawned.stderr

    // The reads block on a dedicated thread and feed chunks through a stream,
    // so the parsing task — which must await `onOutput` — only ever suspends.
    let stdoutChunks = AsyncStream<Data> { continuation in
      let thread = Thread {
        while true {
          let data = stdoutHandle.availableData
          if data.isEmpty { break }
          continuation.yield(data)
        }
        continuation.finish()
      }
      thread.name = "oxbow.helper-stdout"
      thread.start()
    }

    let stdoutPump = Task.detached { [dialect = launch.dialect] in
      var parser = DialectParser(dialect)
      for await data in stdoutChunks {
        for line in parser.consume(data) { await onOutput(line) }
      }
      if let tail = parser.finish() { await onOutput(tail) }
    }

    let stderrPump = Task.detached {
      await BlockingThread.run("oxbow.helper-stderr") { () -> String in
        var accumulated = Data()
        while true {
          let data = stderrHandle.availableData
          if data.isEmpty { break }
          accumulated.append(data)
        }
        return String(decoding: accumulated, as: UTF8.self)
      }
    }

    let pid = spawned.pid
    let status = await BlockingThread.run("oxbow.helper-waitpid") { ProcessSpawner.wait(pid) }

    await stdoutPump.value
    let standardError = await stderrPump.value

    self.spawned = nil
    return RunResult(status: status, standardError: standardError)
  }

  /// Signals the whole process group so the helper's FFmpeg goes with it.
  public func cancel() async {
    isCancelled = true
    guard let spawned else { return }
    let pid = spawned.pid

    ProcessSpawner.signal(SIGTERM, toGroupOf: pid)

    // Detach the grace-period sleep from caller cancellation; otherwise cancellation makes it
    // throw immediately and SIGKILL follows SIGTERM without delay.
    try? await Task.detached { try await Task.sleep(for: .seconds(2)) }.value

    // Re-read `spawned` after sleeping. `run` may have reaped the child and cleared it;
    // signalling the old PID risks hitting a recycled process group.
    guard let stillRunning = self.spawned, stillRunning.pid == pid else { return }
    ProcessSpawner.signal(SIGKILL, toGroupOf: stillRunning.pid)
  }
}
