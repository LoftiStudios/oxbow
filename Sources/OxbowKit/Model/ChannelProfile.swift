import Foundation

/// Channel profile fetched at watch creation, not every sweep.
public struct ChannelProfile: Equatable, Sendable {
  public let displayName: String

  /// Optional avatar at ChannelFeed.avatarWidth; the CDN accepts only fixed sizes.
  public let avatarURL: URL?

  public init(displayName: String, avatarURL: URL?) {
    self.displayName = displayName
    self.avatarURL = avatarURL
  }
}
