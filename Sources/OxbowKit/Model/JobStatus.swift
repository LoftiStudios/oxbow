public enum JobStatus: Sendable, Equatable {
  case queued, running, done, failed, cancelled
}

extension JobStatus {
  /// Whether this job is still going to produce something.
  ///
  /// The test the duplicate rule asks. `failed` and `cancelled` are
  /// deliberately *finished*: refusing a second attempt at one of those
  /// would leave someone unable to re-queue a download that went wrong from
  /// the one surface that has no queue window to retry it in.
  public var isUnfinished: Bool {
    switch self {
    case .queued, .running: true
    case .done, .failed, .cancelled: false
    }
  }
}
