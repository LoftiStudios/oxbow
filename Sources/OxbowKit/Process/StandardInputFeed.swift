import Foundation
import Synchronization

/// Something a process reads on its stdin while it runs: the native renderer's chat frames,
/// piped into the composite's FFmpeg. Written from a thread of its own; it should return once
/// `stop` is set, and a failed write — the process gone — ends it too.
public struct StandardInputFeed: Sendable {
  public let write: @Sendable (FileHandle, StopFlag) -> Void

  public init(write: @escaping @Sendable (FileHandle, StopFlag) -> Void) {
    self.write = write
  }
}

/// A cancellation flag shared by reference with a writer thread, which a non-copyable `Atomic`
/// cannot be.
public final class StopFlag: Sendable {
  private let value = Atomic<Bool>(false)

  public init() {}

  public var isSet: Bool { value.load(ordering: .relaxed) }
  public func set() { value.store(true, ordering: .relaxed) }
}
