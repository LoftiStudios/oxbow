import Foundation
import Testing
@testable import Oxbow

@MainActor
@Suite("Queue host")
struct QueueHostTests {

  /// The whole point: an intent and a window both asking for the engine must
  /// get one engine. A second `QueueEngine` over the same queue.json and the
  /// same workspace is what `OxbowApp`'s `Window` comment exists to prevent,
  /// and `start()` sweeps that workspace unconditionally — so a duplicate
  /// deletes the working files of a download already in flight.
  @Test func concurrentCallersResolveExactlyOnce() async {
    let count = Counter()
    let host = QueueHost(resolve: {
      await count.increment()
      try? await Task.sleep(for: .milliseconds(20))
      return .unavailable("stub")
    })

    async let first = host.ready()
    async let second = host.ready()
    async let third = host.ready()
    _ = await (first, second, third)

    #expect(await count.value == 1)
  }

  @Test func laterCallersGetTheSameAnswerWithoutResolvingAgain() async {
    let count = Counter()
    let host = QueueHost(resolve: {
      await count.increment()
      return .unavailable("only once")
    })

    _ = await host.ready()
    let second = await host.ready()

    #expect(await count.value == 1)
    guard case .unavailable(let message) = second else {
      Issue.record("expected .unavailable, got \(second)")
      return
    }
    #expect(message == "only once")
  }

  /// A missing payload must be *delivered*, never awaited. An intent that
  /// waits forever for an engine that will never exist is the failure mode
  /// this whole type is here to prevent.
  @Test func anUnavailableEngineIsDeliveredNotAwaited() async {
    let host = QueueHost(resolve: { .unavailable("The helper is not embedded") })

    let content = await host.ready()

    guard case .unavailable(let message) = content else {
      Issue.record("expected .unavailable, got \(content)")
      return
    }
    #expect(message == "The helper is not embedded")
    #expect(host.resolvedController == nil)
  }
}

/// Actor rather than a plain counter: the resolver runs inside a `Task` and
/// three callers race it, which is exactly the condition a non-isolated
/// `var` would report wrongly.
private actor Counter {
  private(set) var value = 0
  func increment() { value += 1 }
}
