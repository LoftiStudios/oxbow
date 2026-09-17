import Foundation

/// Pure decision for notifying about waiting findings; the inbox retains the actual work.
public enum FindingAnnouncement {

  /// Nil message means no notification, distinct from an empty title.
  public struct Message: Equatable, Sendable {
    public let title: String
    public let body: String
  }

  /// Always replace the caller's announced set, including when message is nil, to prune ids no
  /// longer waiting.
  public struct Decision: Equatable, Sendable {
    public let message: Message?
    public let announced: Set<String>
  }

  /// Filter complete sweep results by each current watch's seen set and exclude submitted ids.
  /// Announce newly waiting ids relative to alreadyAnnounced. Keep that set per process:
  /// relaunch may announce remaining findings again. Fetch failures add no findings; their
  /// errors belong in the inbox.
  public static func decide(
    results: [WatchPollResult],
    watches: [Watch],
    submitted: Set<String>,
    alreadyAnnounced: Set<String>
  ) -> Decision {
    let byLogin = Dictionary(watches.map { ($0.login, $0) }, uniquingKeysWith: { first, _ in first })

    // Retain channel grouping so the title can name one channel or count several.
    let waiting = results.compactMap { result -> (displayName: String, archives: [ChannelArchive])? in
      // Ignore results for watches removed while the sweep was in flight.
      guard let watch = byLogin[result.login] else { return nil }
      return (result.displayName,
              watch.findings(in: result.archives).filter { !submitted.contains($0.id) })
    }

    let waitingIDs = Set(waiting.flatMap { $0.archives.map(\.id) })
    let fresh = waiting
      .map { ($0.displayName, $0.archives.filter { !alreadyAnnounced.contains($0.id) }) }
      .filter { !$0.1.isEmpty }

    let announced = waitingIDs

    let freshCount = fresh.reduce(0) { $0 + $1.1.count }
    guard freshCount > 0 else { return Decision(message: nil, announced: announced) }

    let title = if fresh.count == 1 {
      freshCount == 1
        ? "New archive from \(fresh[0].0)"
        : "\(freshCount) new archives from \(fresh[0].0)"
    } else {
      "\(freshCount) new archives from \(fresh.count) channels"
    }

    let body = waitingIDs.count == 1
      ? "1 archive is waiting in Watching."
      : "\(waitingIDs.count) archives are waiting in Watching."

    return Decision(message: Message(title: title, body: body), announced: announced)
  }
}
