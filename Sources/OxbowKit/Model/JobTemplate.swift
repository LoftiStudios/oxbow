import Foundation

/// Expands download requests into a dependency graph. Composite implies render, and render
/// implies JSON chat; the runtime uses the resulting steps without retaining the template.
public struct JobTemplate: Sendable {
  public enum Media: Sendable {
    case video(VideoRequest)
    case clip(ClipRequest)
  }

  public var media: Media?
  /// - Note: when paired with `render`, this is always downloaded as JSON,
  ///   whatever `ChatRequest.format` says — see `renderInput(_:)`.
  public var chat: ChatRequest?
  public var render: RenderRequest?
  /// Stacks media and rendered chat. Implies a render if absent, but callers must supply
  /// geometry matching the video: the default 350x600 render will fail `hstack` for other
  /// heights. Intake supplies matching geometry.
  public var composite: CompositeRequest?
  /// Records the user's permission to replace an existing destination file. Delivery uses this
  /// decision rather than current file existence; without permission it chooses an unused name.
  public var replacesExistingFile: Bool

  public init(
    media: Media? = nil,
    chat: ChatRequest? = nil,
    render: RenderRequest? = nil,
    composite: CompositeRequest? = nil,
    replacesExistingFile: Bool = false)
  {
    self.media = media
    self.chat = chat
    self.render = render
    self.composite = composite
    self.replacesExistingFile = replacesExistingFile
  }

  /// `nextStepID` is injected rather than calling `UUID()` directly so that
  /// tests can assert against specific steps.
  public func makeJob(
    id: JobID,
    title: String,
    created: Date,
    nextStepID: () -> StepID)
    -> Job
  {
    var steps: [Step] = []

    // Create the independent media step now; append it after chat/render to give chat the first
    // network slot.
    var mediaStep: Step?
    if let media {
      switch media {
      case .video(let request):
        mediaStep = Step(id: nextStepID(), kind: .downloadVideo(request))
      case .clip(let request):
        mediaStep = Step(id: nextStepID(), kind: .downloadClip(request))
      }
    }

    var chatStep: Step?
    if render != nil || composite != nil {
      // Render implies chat; composite implies render. Implied chat stays in the workspace.
      // Callers must supply matching render geometry for composites.
      let request = Self.renderInput(chat ?? Self.impliedChatRequest(for: media))
      chatStep = Step(id: nextStepID(), kind: .downloadChat(request))
    } else if let chat {
      chatStep = Step(id: nextStepID(), kind: .downloadChat(chat))
    }
    if let chatStep {
      steps.append(chatStep)
    }

    var renderStep: Step?
    if let chatStep, render != nil || composite != nil {
      renderStep = Step(
        id: nextStepID(),
        kind: .renderChat(render ?? RenderRequest()),
        dependsOn: [chatStep.id])
      steps.append(renderStep!)
    }

    // Order controls scheduling: chat must claim the network slot before video so its render
    // can overlap the video download. Appending media first serializes all three steps; see
    // `docs/design/compositing.md` §6.
    if let mediaStep {
      steps.append(mediaStep)
    }

    // A composite requires media; there is no source to synthesize when it is absent.
    var compositeStep: Step?
    if let composite, let mediaStep, let renderStep {
      compositeStep = Step(
        id: nextStepID(),
        kind: .composite(composite),
        // Dependency order is `[media, render]`: FFmpeg uses it for layout and audio mapping.
        dependsOn: [mediaStep.id, renderStep.id])
      steps.append(compositeStep!)
    }

    // Assembly is a separate FFmpeg invocation even for one piece, keeping delivery on one
    // path. It needs only retained pieces and audio, so the downloaded video can be deleted
    // first. See `docs/design/resume.md` §6.
    if let composite, let compositeStep {
      steps.append(Step(
        id: nextStepID(),
        kind: .assemble(AssembleRequest(destination: composite.destination)),
        dependsOn: [compositeStep.id]))
    }

    return Job(
      id: id,
      created: created,
      title: title,
      steps: steps,
      replacesExistingFile: replacesExistingFile)
  }

  /// Seeds implied chat with the VOD ID or clip slug. VOD trims must match the media trim to
  /// keep chat aligned. With no media, the ID remains empty.
  private static func impliedChatRequest(for media: Media?) -> ChatRequest {
    switch media {
    case .video(let request):
      return ChatRequest(
        videoID: request.videoID,
        trimStart: request.trimStart,
        trimEnd: request.trimEnd,
        format: .json,
        destination: nil)
    case .clip(let request):
      return ChatRequest(videoID: request.clipSlug, format: .json, destination: nil)
    case nil:
      return ChatRequest(videoID: "", format: .json, destination: nil)
    }
  }

  /// The renderer accepts only JSON. Coerce the request and destination extension together so
  /// public callers cannot deliver JSON under an HTML/text filename. `makeJob` has no error
  /// channel; intake already requests JSON without a separate destination.
  private static func renderInput(_ request: ChatRequest) -> ChatRequest {
    var request = request
    request.format = .json
    if let destination = request.destination,
       destination.pathExtension.lowercased() != "json"
    {
      request.destination = destination.deletingPathExtension().appendingPathExtension("json")
    }
    return request
  }
}
