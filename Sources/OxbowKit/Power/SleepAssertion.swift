import Foundation

/// Keeps the Mac from idling to sleep while the queue has work in flight.
///
/// A protocol rather than a direct `ProcessInfo` call so the engine's
/// behaviour is testable: `ProcessInfo.beginActivity` has no observable
/// effect a test can assert on, and asserting on the *decision* is the part
/// that can regress.
public protocol SleepAsserting: Sendable {

  /// Declares whether work is in flight right now.
  ///
  /// - Important: must be idempotent. `QueueEngine` calls this on every
  ///   change to the set of running steps, which means repeated `true` while
  ///   several steps run alongside each other and repeated `false` while the
  ///   queue sits idle. Only the transitions may have an effect.
  func setActive(_ active: Bool)
}

/// The real assertion, held against `ProcessInfo`.
///
/// **This does not survive closing the lid.** macOS forces sleep on a laptop
/// whose lid closes with no external display attached, and no activity
/// assertion overrides that — it is enforced below the level any application
/// can reach. What this fixes is the ordinary case: the Mac sitting open,
/// nobody touching it, and Energy Saver idling it down forty minutes into a
/// seventy-minute encode. "Start it and shut the lid" cannot be made to work
/// from inside the app, so please don't re-litigate this later.
public final class SystemSleepAssertion: SleepAsserting, @unchecked Sendable {

  /// `.userInitiated` is the composite of `.idleSystemSleepDisabled`,
  /// `.suddenTerminationDisabled` and `.automaticTerminationDisabled`, and we
  /// want all three: the queue must outlive an idle timer, must not be
  /// sudden-terminated mid-encode, and must not be automatically terminated
  /// while it looks idle to the OS but is waiting on a child process.
  ///
  /// Deliberately **not** `.idleDisplaySleepDisabled`. An eighty-eight minute
  /// composite is no reason to hold someone's screen on all night.
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
