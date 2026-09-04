import Foundation
import Observation
import OxbowKit

/// Runs a sweep of the watched channels and republishes the results for
/// SwiftUI.
///
/// **Timing and wiring only.** When a sweep is due is `WatchPollPolicy`; what a
/// sweep produces is `WatchPoll.sweep`. Both are in `OxbowKit` and both are
/// tested without a window. What is left here is the `Task`, and it is here
/// because a `Task` is not a decision.
///
/// **Polls at launch and then on an interval while the app runs — no agent.**
/// `docs/design/channel-watching.md` §5.1 argues this from measurement: the
/// shortest archive-retention window observed was 43 days, so a Mac that is
/// awake occasionally still beats the deadline comfortably. A launch agent
/// would buy coverage for the user who does not open Oxbow for six weeks, and
/// would cost a second process contending for state `QueueEngine` will not
/// share.
@MainActor
@Observable
final class WatchPoller {

  /// The most recent sweep. Empty until the first one lands.
  ///
  /// The inbox is derived from this rather than accumulated
  /// (`docs/design/channel-watching.md` §4), so replacing it wholesale is
  /// correct: an archive that has expired since the last sweep simply stops
  /// appearing, which is what should happen to a row nothing can download.
  private(set) var results: [WatchPollResult] = []

  /// True while a sweep is in flight, so the UI can say so rather than looking
  /// idle for however long a handful of network round trips takes.
  private(set) var isSweeping = false

  private(set) var lastPolled: Date?

  private let store: WatchStore
  private let feed: ChannelFeed
  private let now: () -> Date
  private var loop: Task<Void, Never>?

  /// Both collaborators are injected rather than built here so a preview can
  /// supply a fixed answer without a network or a support directory.
  init(store: WatchStore, feed: ChannelFeed, now: @escaping () -> Date = Date.init) {
    self.store = store
    self.feed = feed
    self.now = now
  }

  /// The live one, reading the watch file `AppComposition` sites and talking to
  /// Twitch over an ephemeral session.
  ///
  /// Ephemeral for the same reason `UpdateCheck`'s is: nothing here benefits
  /// from a URL cache, and a cached answer is precisely the wrong thing for a
  /// question whose whole purpose is "has anything changed".
  static func live(supportDirectory: URL) -> WatchPoller {
    let configuration = URLSessionConfiguration.ephemeral
    let session = URLSession(configuration: configuration)
    return WatchPoller(
      store: WatchStore(fileURL: AppComposition.watchStoreURL(supportDirectory: supportDirectory)),
      feed: ChannelFeed(fetch: { request in
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
          throw ChannelFeedError.malformedPayload(snippet: "")
        }
        return (data, http)
      }))
  }

  /// Sweeps once now, then every `WatchPollPolicy.interval` for as long as the
  /// app runs.
  ///
  /// Idempotent: calling it twice does not start a second loop. The queue
  /// window's `.task` may run more than once across a scene's lifetime, and two
  /// loops would double the traffic for no benefit.
  func start() {
    guard loop == nil else { return }
    loop = Task { [weak self] in
      while !Task.isCancelled {
        await self?.sweepIfDue()
        try? await Task.sleep(for: .seconds(WatchPollPolicy.interval))
      }
    }
  }

  func stop() {
    loop?.cancel()
    loop = nil
  }

  /// A `Task` outlives the object that started it unless something cancels
  /// it, so without this the hourly loop would keep waking for the life of
  /// the process even after this instance is gone.
  isolated deinit {
    loop?.cancel()
  }

  /// A person asked. Never throttled, for the same reason `UpdateModel`'s
  /// manual check is not: pressing a button is an explicit request and must
  /// produce an answer.
  func refreshNow() async {
    await sweep()
  }

  private func sweepIfDue() async {
    guard WatchPollPolicy.shouldPoll(now: now(), lastPolled: lastPolled) else { return }
    await sweep()
  }

  private func sweep() async {
    guard !isSweeping else { return }

    // A watch file that cannot be read is not an empty watch list — but
    // `WatchStore.load` already sets an unreadable file aside and returns
    // empty, so there is nothing here to distinguish. The throw that remains
    // is an unreadable *directory*, which is the same condition that stops
    // the queue loading, and the queue reports it first.
    //
    // Either way, `results` still gets cleared below rather than left as-is:
    // an empty list and an unreadable file both mean "nothing to report",
    // and neither is evidence that the archives found on the last successful
    // sweep are still there. Leaving stale rows behind because this sweep
    // couldn't ask would tell the user about downloads that may no longer
    // exist.
    let watches = (try? store.load()) ?? []
    guard !watches.isEmpty else {
      results = []
      return
    }

    isSweeping = true
    let swept = await WatchPoll.sweep(watches) { login in
      do {
        return .success(try await feed.archives(forLogin: login))
      } catch let error as ChannelFeedError {
        return .failure(error)
      } catch {
        // URLSession's own errors — offline, DNS, TLS. Reported as their own
        // case rather than squeezed into an existing one: `.server(status: 0)`
        // would render as "Twitch answered with status 0", which blames Twitch
        // for the user's wifi, and `.malformedPayload` would blame it for a
        // response that never arrived.
        return .failure(.unreachable(error.localizedDescription))
      }
    }
    results = swept
    lastPolled = now()
    isSweeping = false
  }
}
