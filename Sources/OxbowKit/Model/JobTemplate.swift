import Foundation

/// A user intent, before it becomes steps.
///
/// Templates exist only at construction time. Once expanded, the runtime model
/// is uniform and nothing needs to know which template produced a job.
public enum JobTemplate: Sendable {
  case video(VideoRequest)
  case clip(ClipRequest)
  case chat(ChatRequest)
  case chatAndRender(ChatRequest, RenderRequest)
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
      let chatStep = Step(id: nextStepID(), kind: .downloadChat(chatRequest))
      steps = [
        chatStep,
        Step(id: nextStepID(), kind: .renderChat(renderRequest), dependsOn: chatStep.id),
      ]

    case .videoChatAndRender(let videoRequest, let chatRequest, let renderRequest):
      let chatStep = Step(id: nextStepID(), kind: .downloadChat(chatRequest))
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
}
