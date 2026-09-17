/// Scheduler resource group, with at most one running step per class. Each helper invocation
/// also uses three dedicated blocking threads; increasing concurrency increases that thread
/// count.
public enum ResourceClass: Sendable, Equatable, CaseIterable {
  case network
  case compute
}
