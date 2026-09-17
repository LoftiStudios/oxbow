/// Distinguishes normal exit, signal termination, and wait failure. Named to avoid collision
/// with `Testing.ExitStatus`.
public enum ProcessExitStatus: Sendable, Equatable {
  case exited(Int32)
  case signalled(Int32)
  /// Unknown status after a `waitpid` failure; must never count as success.
  case waitFailed(errno: Int32)
}
