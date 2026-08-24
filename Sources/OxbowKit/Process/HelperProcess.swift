import Darwin
import Foundation

/// Runs one CLI invocation to completion.
///
/// Cancellation is deliberately blunt: the CLI passes a CancellationToken that
/// can never fire and installs no signal handler, so there is no cooperative
/// path. SIGTERM first is purely for FFmpeg's benefit — it closes its output
/// file on receipt — and SIGKILL follows regardless.
public actor HelperProcess {
  private var spawned: Spawn?
  private var isCancelled = false

  public init() {}

  public func run(
    _ launch: Launch,
    onOutput: @escaping @Sendable (ParsedLine) async -> Void)
    async throws -> RunResult
  {
    let spawned = try ProcessSpawner.spawn(
      executable: launch.executable,
      arguments: launch.arguments,
      workingDirectory: launch.workingDirectory)
    self.spawned = spawned

    // Cancelled between the caller's decision and the spawn actually happening.
    if isCancelled {
      ProcessSpawner.signal(SIGKILL, toGroupOf: spawned.pid)
    }

    let stdoutHandle = spawned.stdout
    let stderrHandle = spawned.stderr

    let stdoutPump = Task.detached {
      var parser = StatusLineParser()
      while true {
        let data = stdoutHandle.availableData
        if data.isEmpty { break }
        for line in parser.consume(data) { await onOutput(line) }
      }
      if let tail = parser.finish() { await onOutput(tail) }
    }

    let stderrPump = Task.detached { () -> String in
      var accumulated = Data()
      while true {
        let data = stderrHandle.availableData
        if data.isEmpty { break }
        accumulated.append(data)
      }
      return String(decoding: accumulated, as: UTF8.self)
    }

    let pid = spawned.pid
    let status = await Task.detached { ProcessSpawner.wait(pid) }.value

    await stdoutPump.value
    let standardError = await stderrPump.value

    self.spawned = nil
    return RunResult(status: status, standardError: standardError)
  }

  /// Signals the whole process group so the helper's FFmpeg goes with it.
  public func cancel() async {
    isCancelled = true
    guard let spawned else { return }

    ProcessSpawner.signal(SIGTERM, toGroupOf: spawned.pid)
    try? await Task.sleep(for: .seconds(2))
    ProcessSpawner.signal(SIGKILL, toGroupOf: spawned.pid)
  }
}
