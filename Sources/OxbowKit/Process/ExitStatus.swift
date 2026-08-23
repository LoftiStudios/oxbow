/// How a child process ended.
///
/// Keeping these apart is what lets us tell "the user cancelled it" from "it
/// crashed" — a distinction Foundation's `Process` blurs.
public enum ExitStatus: Sendable, Equatable {
  case exited(Int32)
  case signalled(Int32)
}
