import Foundation

/// A user intent, before it becomes steps.
///
/// Templates exist only at construction time. Once expanded, the runtime model
/// is uniform and nothing needs to know which template produced a job.
///
/// Four parts, not a fixed list of combinations — but not four independent
/// toggles either: `composite` implies `render` exactly as `render` implies
/// `chat`, so setting it alone still produces a chat-download, render, and
/// composite step. `makeJob` wires only the dependencies each implication
/// actually needs: a render depends on its chat download, and a composite
/// depends on both its media and its render.
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
  /// Stacks the finished media and the finished render into one file. Implies
  /// a render exactly as `render` implies a chat download — asking for a
  /// composite without one is enough to get all four steps. An implied
  /// `RenderRequest()` carries default geometry (350x600 at 30fps), which
  /// will not match a real video's height; `hstack` then fails immediately
  /// and loudly, which is the designed behaviour, but a library caller
  /// composing a template directly should set the render's geometry itself.
  /// The intake always does.
  public var composite: CompositeRequest?

  public init(
    media: Media? = nil,
    chat: ChatRequest? = nil,
    render: RenderRequest? = nil,
    composite: CompositeRequest? = nil)
  {
    self.media = media
    self.chat = chat
    self.render = render
    self.composite = composite
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
    //
    // Its `nextStepID()` is drawn here, before chat/render, but it is not
    // *appended* until after them, below — see the note there for why the
    // append order is load-bearing.
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
      // A render implies a chat step even when the caller supplied no chat
      // request of its own, so that render-without-chat is never silently
      // dropped. The implied request has `destination: nil` so the chat file
      // stays an intermediate and is discarded with the workspace.
      //
      // A composite implies a render exactly the same way, one level up: a
      // caller who sets `composite` without `render` still wants a stacked
      // file, not a silently discarded request, and `makeJob` has no error
      // channel to refuse with (see `renderInput`'s note on the same
      // problem). The implied render carries default geometry, which will
      // fail loudly in `hstack` if it does not match the video — see the
      // note on `composite` above.
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

    // LOAD-BEARING ORDER, not cosmetic: appended after chat and render, even
    // though `mediaStep` was built first, above. `Scheduler.admissible` caps
    // running steps at one per `ResourceClass` and walks `job.steps` in
    // array order, so whichever `.network` step appears first claims that
    // slot. Both this step and the chat download are `.network` (see
    // `StepKind.resource`) — appending media first would let the (long)
    // video download claim the slot and make the (short) chat wait behind
    // it, then the render wait on the chat, the fully-serial timeline
    // docs/design/compositing.md §6 rejected. Appending chat first instead
    // lets the render (`.compute`) and this step (`.network`) become
    // admissible together, in the same call, once the chat finishes. Do not
    // "tidy" this back above chat/render.
    if let mediaStep {
      steps.append(mediaStep)
    }

    // Only when there is genuinely something to stack. Unlike `renderStep`
    // (which `composite` itself implies, above), media is the one input a
    // composite cannot manufacture for itself — there is nothing to stack
    // the chat against — so a composite requested with no media is
    // genuinely left unbuilt.
    if let composite, let mediaStep, let renderStep {
      steps.append(Step(
        id: nextStepID(),
        kind: .composite(composite),
        // ORDER IS THE CONTRACT: ArgumentBuilder reads input 0 as the video
        // and input 1 as the chat render. Swapping these does not resize
        // anything — `hstack` does not scale its inputs — so the frame comes
        // out chat-on-the-left at full size, and worse, silently loses audio:
        // `-map 0:a:0?` would then point at input 0, which is the chat
        // render, and a chat render has no audio track.
        dependsOn: [mediaStep.id, renderStep.id]))
    }

    // Delivery is its own step because joining pieces is a second FFmpeg
    // invocation and `QueueEngine.launch` runs one process per step. On the
    // ordinary path there is exactly one piece and this is a cheap copy; on
    // a resumed job it is a real concat. See docs/design/resume.md §6.
    //
    // Depends on the composite alone. The audio it maps was copied out by
    // the composite's first attempt into the retention area, so the
    // downloaded video is not an input and can be deleted before this runs.
    if let composite, mediaStep != nil, let compositeStep = steps.last {
      steps.append(Step(
        id: nextStepID(),
        kind: .assemble(AssembleRequest(destination: composite.destination)),
        dependsOn: [compositeStep.id]))
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
  /// actually in there. Intake never hits this: `IntakeModel` gives a
  /// composite's chat request no destination at all, since the composite is
  /// its only output, so there is nothing here for this to rewrite.
  /// `JobTemplate` is public library surface, though, and a caller composing
  /// its own template gets no such protection.
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
