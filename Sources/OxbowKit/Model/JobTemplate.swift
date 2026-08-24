import Foundation

/// A user intent, before it becomes steps.
///
/// Templates exist only at construction time. Once expanded, the runtime model
/// is uniform and nothing needs to know which template produced a job.
public enum JobTemplate: Sendable {
  case video(VideoRequest)
  case clip(ClipRequest)
  case chat(ChatRequest)
  /// - Note: the chat half is always downloaded as JSON, whatever
  ///   `ChatRequest.format` says — see `renderInput(_:)`.
  case chatAndRender(ChatRequest, RenderRequest)
  /// - Note: the chat half is always downloaded as JSON, whatever
  ///   `ChatRequest.format` says — see `renderInput(_:)`.
  case videoChatAndRender(VideoRequest, ChatRequest, RenderRequest)

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

    switch self {
    case .video(let request):
      steps = [Step(id: nextStepID(), kind: .downloadVideo(request))]

    case .clip(let request):
      steps = [Step(id: nextStepID(), kind: .downloadClip(request))]

    case .chat(let request):
      steps = [Step(id: nextStepID(), kind: .downloadChat(request))]

    case .chatAndRender(let chatRequest, let renderRequest):
      let chatStep = Step(id: nextStepID(), kind: .downloadChat(Self.renderInput(chatRequest)))
      steps = [
        chatStep,
        Step(id: nextStepID(), kind: .renderChat(renderRequest), dependsOn: chatStep.id),
      ]

    case .videoChatAndRender(let videoRequest, let chatRequest, let renderRequest):
      let chatStep = Step(id: nextStepID(), kind: .downloadChat(Self.renderInput(chatRequest)))
      steps = [
        // Independent of the chat steps: a failed video download must not
        // block the render, and vice versa.
        Step(id: nextStepID(), kind: .downloadVideo(videoRequest)),
        chatStep,
        Step(id: nextStepID(), kind: .renderChat(renderRequest), dependsOn: chatStep.id),
      ]
    }

    return Job(id: id, created: created, title: title, steps: steps)
  }

  /// Constrains a chat download that feeds a render to JSON.
  ///
  /// The renderer reads nothing else: upstream's `chatrender -i` is documented
  /// "Path to JSON chat file input" and hands the file straight to
  /// `ParseJsonAsync()`. Accepting `.html` or `.text` here meant sitting
  /// through a full chat download — minutes, for a long VOD — only to hit a
  /// JSON parse exception in the step that consumes it.
  ///
  /// Constrained rather than rejected because there is nothing to reject:
  /// `makeJob` has no error channel, a `precondition` would crash the app on
  /// user input, and making it throwing would push a failure the caller can
  /// never usefully handle up through `QueueEngine.enqueue`. In a render
  /// pairing the chat file is an intermediate — the user asked for a video,
  /// not a chat log — so its format is ours to pick, not theirs. A user who
  /// wants HTML chat asks for a chat job.
  private static func renderInput(_ request: ChatRequest) -> ChatRequest {
    var request = request
    request.format = .json
    return request
  }
}
