import Synchronization
@testable import OxbowKit

/// Hands out `FakeHelper.Behaviour`s in call order.
///
/// Lets a test control what each successive `QueueEngine.Configuration.
/// makeProcess()` call returns — e.g. the first step launched succeeds while
/// the second hangs until cancelled — without needing `makeProcess` itself
/// to be anything but a plain, synchronous, `@Sendable` closure.
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
