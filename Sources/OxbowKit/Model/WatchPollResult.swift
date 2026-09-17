import Foundation

/// A channel sweep's success or failure. Keep failures distinct from an empty archive list so
/// the UI can report them.
public struct WatchPollResult: Equatable, Sendable {

  public enum Outcome: Equatable, Sendable {
    /// All returned archives; each consumer applies its own seen-state filter.
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

  /// Archives for counting/rendering; returns none on failure. Use `outcome` to determine
  /// channel health.
  public var archives: [ChannelArchive] {
    switch outcome {
    case .found(let archives): archives
    case .failed: []
    }
  }
}
