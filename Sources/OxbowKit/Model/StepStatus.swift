public enum StepStatus: Codable, Sendable, Equatable {
  case queued
  /// An upstream step failed or was cancelled, so this one cannot start.
  case blocked
  case running
  case done
  case failed(StepFailure)
  case cancelled
}
