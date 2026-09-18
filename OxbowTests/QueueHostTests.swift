import Foundation
import Testing
@testable import Oxbow

@MainActor
@Suite("Queue host")
struct QueueHostTests {

  /// Concurrent window/intent resolution must share one engine; a second start would sweep
  /// active workspace files.
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

  /// Missing helper payload must resolve as failure rather than leave callers awaiting forever.
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

/// Isolate the counter because concurrent resolver callers race it.
private actor Counter {
  private(set) var value = 0
  func increment() { value += 1 }
}
