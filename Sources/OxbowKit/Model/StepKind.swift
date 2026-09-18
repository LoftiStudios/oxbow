import Foundation

public enum StepKind: Codable, Sendable, Equatable {
  case downloadVideo(VideoRequest)
  case downloadClip(ClipRequest)
  case downloadChat(ChatRequest)
  case renderChat(RenderRequest)
  case composite(CompositeRequest)
  case assemble(AssembleRequest)

  /// Derived, never stored — a stored copy could drift from the kind.
  public var resource: ResourceClass {
    switch self {
    case .downloadVideo, .downloadClip, .downloadChat: .network
    case .renderChat, .composite, .assemble: .compute
    }
  }

  /// Destination for a delivered output; nil for intermediates. Composite produces retained
  /// pieces, while assemble delivers the final file. `JobTemplate` forwards
  /// `CompositeRequest.destination` to assembly.
  public var deliveryDestination: URL? {
    switch self {
    case .downloadVideo(let request): request.destination
    case .downloadClip(let request): request.destination
    case .downloadChat(let request): request.destination
    case .renderChat(let request): request.destination
    case .composite: nil
    case .assemble(let request): request.destination
    }
  }
}
