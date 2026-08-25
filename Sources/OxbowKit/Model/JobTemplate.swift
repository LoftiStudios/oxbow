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
  /// - Note: when paired with `render`, this is always downloaded as JSON,
  ///   whatever `ChatRequest.format` says — see `renderInput(_:)`.
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
      steps.append(Step(id: nextStepID(), kind: .renderChat(render), dependsOn: [chatStep.id]))
    }

    return Job(id: id, created: created, title: title, steps: steps)
  }

  /// Seeds an implied chat request's ID from the media being downloaded
  /// alongside it. Upstream's `chatdownload --id` documents itself as taking
  /// "a VOD or clip" (design doc §8), so `ChatRequest.videoID` legitimately
  /// holds a clip slug: a `.clip` media seeds the implied chat with its
  /// `clipSlug`, a `.video` media seeds it with its `videoID` *and* the same
  /// `trimStart`/`trimEnd` — otherwise a trimmed video would render against
  /// full-VOD chat, which is silently wrong output, not a cosmetic gap.
  /// With no media at all (render requested on its own, unrepresentable at
  /// real intake — see the design doc, §5) there is nothing to seed it with,
  /// so it is left empty.
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
  ///
  /// The destination follows the format. Rewriting one without the other
  /// delivered JSON bytes inside a file called `… - chat.html`, which is
  /// worse than either honest outcome: the extension is the only thing that
  /// tells the user — or Finder, or the next program to open it — what is
  /// actually in there. Intake never hit this because it derives the
  /// extension from `deliveredChatFormat` after the same override, but
  /// `JobTemplate` is public library surface and a caller composing its own
  /// template gets no such protection.
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
