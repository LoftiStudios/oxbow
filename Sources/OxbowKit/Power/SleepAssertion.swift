import Foundation

/// Injectable idle-sleep assertion while queue work is in flight.
public protocol SleepAsserting: Sendable {

  /// Must be idempotent: the engine calls on every running-set change, including repeated true
  /// or false values.
  func setActive(_ active: Bool)
}

/// Prevents idle sleep, not the forced sleep caused by closing a laptop lid without an external
/// display.
public final class SystemSleepAssertion: SleepAsserting, @unchecked Sendable {

  /// Use `.userInitiated` to prevent idle system sleep and sudden/automatic termination. Allow
  /// display sleep during long jobs.
  private static let options: ProcessInfo.ActivityOptions = [.userInitiated]

  /// Surfaced by `pmset -g assertions`, so it should read as an explanation
  /// to whoever is wondering why their Mac stayed awake.
  private static let reason = "Oxbow is running queued downloads"

  /// Guarded by a lock rather than actor-isolated because the only caller is
  /// a `didSet`, and a property observer cannot `await`.
  private let lock = NSLock()
  private var token: (any NSObjectProtocol)?

  public init() {}

  deinit {
    if let token { ProcessInfo.processInfo.endActivity(token) }
  }

  public func setActive(_ active: Bool) {
    lock.lock()
    defer { lock.unlock() }

    if active {
      guard token == nil else { return }
      token = ProcessInfo.processInfo.beginActivity(options: Self.options, reason: Self.reason)
    } else {
      guard let held = token else { return }
      ProcessInfo.processInfo.endActivity(held)
      token = nil
    }
  }
}
