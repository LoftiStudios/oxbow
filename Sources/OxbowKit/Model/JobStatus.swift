public enum JobStatus: Sendable, Equatable {
  case queued, running, done, failed, cancelled
}
