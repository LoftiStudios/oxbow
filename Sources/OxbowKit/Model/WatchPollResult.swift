import Foundation

/// What one channel's sweep produced.
///
/// **An outcome, not a list.** `docs/design/channel-watching.md` §7 requires
/// that a parse failure degrade to a visible error rather than to an empty
/// list that looks like "no new videos" — so a caller must be unable to
/// confuse the two, which means the failure has to survive as far as the UI.
public struct WatchPollResult: Equatable, Sendable {

  public enum Outcome: Equatable, Sendable {
    /// The sweep succeeded. The payload is what this watch has not seen,
    /// which is legitimately empty most of the time.
    case found([ChannelArchive])
    case failed(ChannelFeedError)
  }

  public let login: String
  public let displayName: String
  public let outcome: Outcome

  public init(login: String, displayName: String, outcome: Outcome) {
    self.login = login
    self.displayName = displayName
    self.outcome = outcome
  }

  /// The findings, with a failure reading as none.
  ///
  /// A convenience for counting and rendering. It deliberately does **not**
  /// replace `outcome` — anything deciding whether a channel is *healthy* must
  /// read `outcome`, because this getter is exactly the flattening §7 forbids
  /// as the only signal.
  public var findings: [ChannelArchive] {
    switch outcome {
    case .found(let archives): archives
    case .failed: []
    }
  }
}
