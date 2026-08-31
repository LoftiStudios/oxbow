import Foundation
@testable import OxbowKit

/// Records every `setActive` call the engine makes, repeats included, so a
/// test can assert both what was decided and how often it flapped.
final class SpySleepAssertion: SleepAsserting, @unchecked Sendable {

  private let lock = NSLock()
  private var recorded: [Bool] = []

  /// Every call, in order — including the no-op repeats a real assertion
  /// swallows.
  var calls: [Bool] {
    lock.lock()
    defer { lock.unlock() }
    return recorded
  }

  /// Only the calls that changed state, which is what the real assertion
  /// would actually act on. Starts from inactive, so a leading `false` is
  /// not a transition.
  var transitions: [Bool] {
    var result: [Bool] = []
    var current = false
    for call in calls where call != current {
      result.append(call)
      current = call
    }
    return result
  }

  /// Whether the Mac would be held awake right now.
  var isActive: Bool { transitions.last ?? false }

  func setActive(_ active: Bool) {
    lock.lock()
    defer { lock.unlock() }
    recorded.append(active)
  }
}
