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

  /// Where this step's own output belongs once it succeeds — `nil` for a
  /// step whose result only feeds a later one. This is `QueueEngine.move`'s
  /// switch, made public rather than kept private and duplicated: the app
  /// layer needs the same answer to know which of a job's steps actually
  /// delivered a file (`Step.deliveredArtifact`), and a second copy of this
  /// switch is exactly how the two could quietly disagree.
  ///
  /// `.composite` is always `nil` despite `CompositeRequest` carrying its
  /// own `destination` — its output is a piece in the retention area, not
  /// the finished file, and a resumed job can produce several. Only
  /// `.assemble`, which joins them, ever delivers under the name the user
  /// chose. `CompositeRequest.destination` still exists — `JobTemplate`
  /// reads it to build the `AssembleRequest` that actually delivers — it is
  /// simply never consulted here.
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
