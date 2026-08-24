import Darwin
import Foundation

/// Runs one CLI invocation to completion.
///
/// Cancellation is deliberately blunt: the CLI passes a CancellationToken that
/// can never fire and installs no signal handler, so there is no cooperative
/// path. SIGTERM first is purely for FFmpeg's benefit — it closes its output
/// file on receipt — and SIGKILL follows regardless.
///
/// - Important: Each `run` pins **three threads** of Swift's cooperative
///   thread pool for the life of the invocation — the stdout pump, the
///   stderr pump, and the `waitpid` call are three **blocking** syscalls
///   inside `Task.detached`, with no suspension point for the runtime to
///   reclaim the thread. (Three pinned threads, not three suspended tasks:
///   counting awaits will not find them.) This is acceptable only because
///   `Scheduler` admits at most one `.network` step and one `.compute` step
///   concurrently, capping concurrent `HelperProcess.run` calls at 2 (6
///   pinned threads worst case). Raising that admission cap without first
///   revisiting this (e.g. moving to `DispatchIO` or a dedicated,
///   non-cooperative thread pool) will starve the cooperative pool.
///
/// One instance drives exactly one invocation of `run`. `cancel()` sets a
/// one-way flag that is never reset, so `run` on an already-cancelled
/// instance returns immediately as killed **without spawning anything** —
/// reuse across invocations is unsupported by design. `QueueEngine` creates a
/// fresh instance per step.
public actor HelperProcess {
  private var spawned: Spawn?
  private var isCancelled = false

  public init() {}

  public func run(
    _ launch: Launch,
    onOutput: @escaping @Sendable (ParsedLine) async -> Void)
    async throws -> RunResult
  {
    // Checked before the spawn, not after: spawning and then immediately
    // killing would still have started a real CLI process, which reaches the
    // network before it dies. The reported status is what the child would
    // have got had it existed long enough to receive it.
    if isCancelled {
      return RunResult(status: .signalled(SIGKILL), standardError: "")
    }

    let spawned = try ProcessSpawner.spawn(
      executable: launch.executable,
      arguments: launch.arguments,
      workingDirectory: launch.workingDirectory)
    self.spawned = spawned

    // Cancelled between the check above and the spawn actually happening —
    // `ProcessSpawner.spawn` is synchronous, but `cancel()` can still have run
    // on this actor before `run` was first entered.
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
    let pid = spawned.pid

    ProcessSpawner.signal(SIGTERM, toGroupOf: pid)

    // Detached so the grace period survives even if the task calling
    // `cancel()` is itself cancelled. `Task.sleep` checks the cancellation
    // of the task it runs on; if it ran on the caller's task directly, an
    // outer cancellation would make it throw instantly, and the `try?`
    // would swallow that — firing SIGKILL immediately and defeating the
    // reason SIGTERM was sent first. A detached task has its own,
    // independent cancellation state, so the sleep completes in full.
    try? await Task.detached { try await Task.sleep(for: .seconds(2)) }.value

    // Re-read actor state instead of trusting the pre-sleep local copy:
    // during those two seconds `run` can complete, reap the child, and
    // clear `self.spawned`. Signalling the stale pid then would hit
    // whatever process has since recycled that pgid — every helper is its
    // own group leader, so pgid == pid — rather than a no-op.
    guard let stillRunning = self.spawned, stillRunning.pid == pid else { return }
    ProcessSpawner.signal(SIGKILL, toGroupOf: stillRunning.pid)
  }
}
