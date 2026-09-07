import Foundation

/// A channel's own metadata, as distinct from its archives.
///
/// Fetched once when a channel is added, never on a poll — see
/// `ChannelFeed.profile(forLogin:)` for why that separation is load-bearing.
public struct ChannelProfile: Equatable, Sendable {
  public let displayName: String

  /// `nil` when the channel has no avatar set, which is ordinary rather than
  /// an error. Sized at `ChannelFeed.avatarWidth`; the CDN serves only a
  /// fixed set of sizes (`docs/twitch-channel-api.md` §9.2).
  public let avatarURL: URL?

  public init(displayName: String, avatarURL: URL?) {
    self.displayName = displayName
    self.avatarURL = avatarURL
  }
}
