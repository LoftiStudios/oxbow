/// What a step contends for. The scheduler admits at most one running step per
/// class, which is what lets a download and a render overlap.
///
/// - Important: the number of classes is also the concurrency cap on
///   `HelperProcess.run`, and each run pins three *blocking* syscalls on
///   Swift's cooperative thread pool. Adding a class — or relaxing the
///   one-per-class rule in `Scheduler.admissible` — raises that cap. Read
///   `HelperProcess`'s note on thread pinning before doing either.
public enum ResourceClass: Sendable, Equatable, CaseIterable {
  case network
  case compute
}
