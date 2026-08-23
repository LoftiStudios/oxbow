/// What a step contends for. The scheduler admits at most one running step per
/// class, which is what lets a download and a render overlap.
public enum ResourceClass: Sendable, Equatable, CaseIterable {
  case network
  case compute
}
