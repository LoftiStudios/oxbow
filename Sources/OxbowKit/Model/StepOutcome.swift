import Foundation

/// What a finished step reports back to the scheduler.
public enum StepOutcome: Sendable, Equatable {
  case succeeded(artifact: URL)
  case failed(StepFailure)
  case cancelled
}
