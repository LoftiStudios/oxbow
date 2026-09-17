import Foundation

/// Runs blocking syscalls on dedicated threads. Blocking the cooperative pool can starve actor
/// jobs, including the cancellation needed to end the process being waited on.
enum BlockingThread {

  /// Runs `body` on a fresh thread while the awaiting task suspends.
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
