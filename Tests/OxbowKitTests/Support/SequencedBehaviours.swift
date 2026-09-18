import Synchronization
@testable import OxbowKit

/// Synchronous, Sendable sequence of helper behaviors shared across launches.
final class SequencedBehaviours: Sendable {
  private let remaining: Mutex<[FakeHelper.Behaviour]>

  init(_ behaviours: [FakeHelper.Behaviour]) {
    remaining = Mutex(behaviours)
  }

  /// Falls back to `.succeeds` once the list is exhausted, so a test only
  /// needs to specify the behaviours it actually cares about.
  func next() -> FakeHelper.Behaviour {
    remaining.withLock { behaviours in
      behaviours.isEmpty ? .succeeds : behaviours.removeFirst()
    }
  }
}
