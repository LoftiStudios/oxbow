import Foundation

/// A user intent, before it becomes steps.
///
/// Templates exist only at construction time. Once expanded, the runtime model
/// is uniform and nothing needs to know which template produced a job.
///
/// The three parts are independent toggles, not a fixed list of combinations:
/// any subset may be present, and `makeJob` wires only the dependency a render
/// actually needs (on its chat download), never one between media and chat.
public struct JobTemplate: Sendable {
  public enum Media: Sendable {
    case video(VideoRequest)
    case clip(ClipRequest)
  }

  public var media: Media?
  public var chat: ChatRequest?
  public var render: RenderRequest?

  public init(media: Media? = nil, chat: ChatRequest? = nil, render: RenderRequest? = nil) {
    self.media = media
    self.chat = chat
    self.render = render
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

    // Independent of the chat/render steps below: a failed video or clip
    // download must not block the render, and vice versa. Never give this
    // step a `dependsOn`.
    if let media {
      switch media {
      case .video(let request):
        steps.append(Step(id: nextStepID(), kind: .downloadVideo(request)))
      case .clip(let request):
        steps.append(Step(id: nextStepID(), kind: .downloadClip(request)))
      }
    }

    var chatStep: Step?
    if render != nil {
      // A render implies a chat step even when the caller supplied no chat
      // request of its own, so that render-without-chat is never silently
      // dropped. The implied request has `destination: nil` so the chat file
      // stays an intermediate and is discarded with the workspace.
      let request = Self.renderInput(chat ?? Self.impliedChatRequest(for: media))
      chatStep = Step(id: nextStepID(), kind: .downloadChat(request))
    } else if let chat {
      chatStep = Step(id: nextStepID(), kind: .downloadChat(chat))
    }
    if let chatStep {
      steps.append(chatStep)
    }

    if let render, let chatStep {
      steps.append(Step(id: nextStepID(), kind: .renderChat(render), dependsOn: chatStep.id))
    }

    return Job(id: id, created: created, title: title, steps: steps)
  }

  /// Seeds an implied chat request's VOD ID from the video being downloaded
  /// alongside it, when there is one. A clip's `clipSlug` is not a VOD ID and
  /// cannot seed a chat download; with no media at all (render requested on
  /// its own, unrepresentable at real intake — see the design doc, §5) there
  /// is nothing to seed it with, so it is left empty.
  private static func impliedChatRequest(for media: Media?) -> ChatRequest {
    let videoID: String
    if case .video(let request) = media {
      videoID = request.videoID
    } else {
      videoID = ""
    }
    return ChatRequest(videoID: videoID, format: .json, destination: nil)
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
