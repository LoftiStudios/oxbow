import Foundation

/// Runs one blocking operation on a dedicated thread of its own, keeping
/// blocking syscalls off Swift's cooperative thread pool entirely.
///
/// The cooperative pool has exactly one thread per core and never grows. A
/// blocking syscall on a pool thread pins it, and enough pinned threads starve
/// every other task in the process — including actor jobs like
/// `HelperProcess.cancel()`, which then cannot run at all. This is not
/// theoretical: on a 3-core CI runner, concurrent test runs pinned the whole
/// pool and a cancellation was starved for the full five minutes of the
/// child's `sleep 300`. A dedicated thread costs ~512 KB of stack for the
/// life of the call, which is cheap next to that failure mode.
enum BlockingThread {

  /// Awaits `body` run on a fresh thread. The awaiting task suspends — it
  /// does not block — so the cooperative pool stays available regardless of
  /// how long `body` blocks.
  static func run<Success: Sendable>(
    _ name: String,
    _ body: @escaping @Sendable () -> Success)
    async -> Success
  {
    await withCheckedContinuation { continuation in
      let thread = Thread { continuation.resume(returning: body()) }
      thread.name = name
      thread.start()
    }
  }
}
