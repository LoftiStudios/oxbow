/// The outcome of one completed `HelperProcess.run`.
public struct RunResult: Sendable {
  public var status: ProcessExitStatus
  /// Kept whole. The CLI reports failures as unhandled exceptions with a stack
  /// trace here, and the useful sentence has to be extracted from it.
  public var standardError: String

  public init(status: ProcessExitStatus, standardError: String) {
    self.status = status
    self.standardError = standardError
  }
}
