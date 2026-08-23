public struct StepFailure: Codable, Sendable, Equatable {
  public enum Kind: Codable, Sendable, Equatable {
    /// The app died while this step was running.
    case interrupted
    case launchFailed(String)
    case exited(code: Int32)
    /// Killed by a signal we did not send — i.e. it crashed.
    case signalled(Int32)
    /// Exited without producing a usable artifact. This, not the exit code, is
    /// the real failure criterion. See the design spec, §1.5.
    case noArtifact
    case moveFailed(String)
  }

  public var kind: Kind
  /// One sentence, shown in the row. Never a stack trace.
  public var summary: String
  /// Full stderr, behind a disclosure, copyable for bug reports.
  public var detail: String?

  public init(kind: Kind, summary: String, detail: String? = nil) {
    self.kind = kind
    self.summary = summary
    self.detail = detail
  }
}
