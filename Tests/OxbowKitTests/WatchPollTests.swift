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

  @Test("a sweep reports only archives the watch has not seen")
  func reportsUnseenOnly() async {
    let results = await WatchPoll.sweep([watch("ninja", seen: ["1"])]) { _ in
      .success([self.archive("1"), self.archive("2")])
    }
    #expect(results.map(\.login) == ["ninja"])
    #expect(results[0].findings.map(\.id) == ["2"])
  }

  @Test("a channel with nothing new reports an empty finding list, not a failure")
  func nothingNewIsSuccess() async {
    let results = await WatchPoll.sweep([watch("ninja", seen: ["1"])]) { _ in
      .success([self.archive("1")])
    }
    #expect(results[0].outcome == .found([]))
    #expect(results[0].findings.isEmpty)
  }

  @Test("a failure is carried, not flattened into an empty list")
  func failureIsCarried() async {
    // The whole point of section 7: a parse failure must be distinguishable
    // from "no new videos", or a watch degrades silently into doing nothing.
    let results = await WatchPoll.sweep([watch("ninja")]) { _ in
      .failure(.malformedPayload(snippet: "…"))
    }
    #expect(results[0].outcome == .failed(.malformedPayload(snippet: "…")))
    #expect(results[0].findings.isEmpty)
  }

  @Test("one channel failing does not stop the others")
  func failureIsIsolated() async {
    let results = await WatchPoll.sweep([watch("a"), watch("b"), watch("c")]) { login in
      login == "b" ? .failure(.noSuchChannel) : .success([self.archive("1")])
    }
    #expect(results.map(\.login) == ["a", "b", "c"])
    #expect(results[0].findings.map(\.id) == ["1"])
    #expect(results[1].outcome == .failed(.noSuchChannel))
    #expect(results[2].findings.map(\.id) == ["1"])
  }

  @Test("results keep the order of the watches given")
  func orderIsStable() async {
    let logins = ["ninja", "day9tv", "wheelyf"]
    let results = await WatchPoll.sweep(logins.map { watch($0) }) { _ in .success([]) }
    #expect(results.map(\.login) == logins)
  }

  @Test("a live broadcast is reported to a person, because a person may still choose it")
  func liveIsReported() async {
    // Section 5.2 forbids anything UNATTENDED queueing a RECORDING. It does not
    // hide it from a human. Stage 3 filters at the point of submission; this
    // must not filter here, or the inbox silently omits a stream someone is
    // watching right now.
    let results = await WatchPoll.sweep([watch("ninja")]) { _ in
      .success([self.archive("1", status: .recording)])
    }
    #expect(results[0].findings.map(\.id) == ["1"])
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
    // Polling is read-only by design: the seen-set changes only when a person
    // Adds or Ignores. A poll that marked findings seen would consume them
    // before anyone saw them.
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
