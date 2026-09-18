public enum JobStatus: Sendable, Equatable {
  case queued, running, done, failed, cancelled
}

extension JobStatus {
  /// Unfinished jobs block duplicates. Failed and cancelled jobs remain eligible for a fresh
  /// attempt.
  public var isUnfinished: Bool {
    switch self {
    case .queued, .running: true
    case .done, .failed, .cancelled: false
    }
  }
}
