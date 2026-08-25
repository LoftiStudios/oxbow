public enum StepKind: Codable, Sendable, Equatable {
  case downloadVideo(VideoRequest)
  case downloadClip(ClipRequest)
  case downloadChat(ChatRequest)
  case renderChat(RenderRequest)
  case composite(CompositeRequest)

  /// Derived, never stored — a stored copy could drift from the kind.
  public var resource: ResourceClass {
    switch self {
    case .downloadVideo, .downloadClip, .downloadChat: .network
    case .renderChat, .composite: .compute
    }
  }
}
