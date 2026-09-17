import Foundation
import Testing
@testable import OxbowKit

@Suite("WatchPoll")
struct WatchPollTests {

  private func watch(_ login: String, seen: Set<String> = []) -> Watch {
    Watch(
      login: login, displayName: login.capitalized,
      settings: .init(destinationPath: "/Users/x/Downloads", qualityCap: .best,
                      output: .videoWithChat, chatSize: .medium),
      downloadsAutomatically: false, seen: seen)
  }

  private func archive(_ id: String, status: ChannelArchive.Status = .recorded) -> ChannelArchive {
    ChannelArchive(id: id, title: "t", duration: .seconds(60),
                   publishedAt: Date(timeIntervalSince1970: 0), status: status, thumbnailURL: nil)
  }

  /// Sweeps return seen archives too so downloaded history remains visible. Consumers needing
  /// findings-only filter separately.
  @Test("returns every archive the channel has, including seen ones")
  func returnsEverythingIncludingSeen() async {
    let results = await WatchPoll.sweep([watch("ninja", seen: ["1"])]) { _ in
      .success([self.archive("1"), self.archive("2")])
    }
    #expect(results.map(\.login) == ["ninja"])
    #expect(results[0].archives.map(\.id) == ["1", "2"])
  }

  @Test("a channel with nothing new reports an empty archive list, not a failure")
  func nothingNewIsSuccess() async {
    let results = await WatchPoll.sweep([watch("ninja")]) { _ in .success([]) }
    #expect(results[0].outcome == .found([]))
    #expect(results[0].archives.isEmpty)
  }

  @Test("a failure is carried, not flattened into an empty list")
  func failureIsCarried() async {
    // Failed parsing must remain distinct from an empty channel.
    let results = await WatchPoll.sweep([watch("ninja")]) { _ in
      .failure(.malformedPayload(snippet: "…"))
    }
    #expect(results[0].outcome == .failed(.malformedPayload(snippet: "…")))
    #expect(results[0].archives.isEmpty)
  }

  @Test("one channel failing does not stop the others")
  func failureIsIsolated() async {
    let results = await WatchPoll.sweep([watch("a"), watch("b"), watch("c")]) { login in
      login == "b" ? .failure(.noSuchChannel) : .success([self.archive("1")])
    }
    #expect(results.map(\.login) == ["a", "b", "c"])
    #expect(results[0].archives.map(\.id) == ["1"])
    #expect(results[1].outcome == .failed(.noSuchChannel))
    #expect(results[2].archives.map(\.id) == ["1"])
  }

  @Test("results keep the order of the watches given")
  func orderIsStable() async {
    let logins = ["ninja", "day9tv", "wheelyf"]
    let results = await WatchPoll.sweep(logins.map { watch($0) }) { _ in .success([]) }
    #expect(results.map(\.login) == logins)
  }

  @Test("a live broadcast is reported to a person, because a person may still choose it")
  func liveIsReported() async {
    // Show recording broadcasts; filter only at unattended submission.
    let results = await WatchPoll.sweep([watch("ninja")]) { _ in
      .success([self.archive("1", status: .recording)])
    }
    #expect(results[0].archives.map(\.id) == ["1"])
  }

  @Test("no watches is an empty sweep, not a fetch")
  func noWatchesFetchesNothing() async {
    let calls = LockedCount()
    let results = await WatchPoll.sweep([]) { _ in
      calls.increment()
      return .success([])
    }
    #expect(results.isEmpty)
    #expect(calls.value == 0)
  }

  @Test("the sweep does not mutate the watches it was given")
  func sweepIsReadOnly() async {
    // Sweeping must not mark findings handled before any action.
    let original = watch("ninja", seen: ["1"])
    _ = await WatchPoll.sweep([original]) { _ in .success([self.archive("2")]) }
    #expect(original.seen == ["1"])
  }
}

/// A `Sendable` counter for asserting how many times an escaping closure ran.
private final class LockedCount: @unchecked Sendable {
  private let lock = NSLock()
  private var storage = 0
  func increment() { lock.withLock { storage += 1 } }
  var value: Int { lock.withLock { storage } }
}
