/// How a child process ended.
///
/// Keeping these apart is what lets us tell "the user cancelled it" from "it
/// crashed" — a distinction Foundation's `Process` blurs.
public enum ExitStatus: Sendable, Equatable {
  case exited(Int32)
  case signalled(Int32)
  /// `waitpid` itself failed (e.g. `ECHILD` because the pid was already
  /// reaped, or `EINVAL`). This must never be silently treated as a clean
  /// exit — that would report a process we know nothing about as having
  /// succeeded.
  case waitFailed(errno: Int32)
}
