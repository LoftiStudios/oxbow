import Foundation
import OxbowKit

/// Everything a finished, running or cancelled job can still say about how it
/// was set up, read back out of the job itself.
///
/// **Nothing new is stored for this.** `Step.kind` carries the whole
/// `VideoRequest` / `ClipRequest` / `ChatRequest` / `RenderRequest` that
/// produced it, and those are `Codable` and live in the persisted queue — so
/// every setting of every job survives a relaunch already, including all
/// twenty render options. Get Info is a reading of what is there, not a second
/// copy of it, which is what keeps the two from ever disagreeing.
///
/// `nonisolated`: the target defaults new declarations to `@MainActor`, but
/// this is a pure derivation from a value with no UI dependency, and
/// `OxbowTests` (which has no actor default of its own) calls it
/// synchronously.
nonisolated struct JobInfo {
  let job: Job

  init(job: Job) {
    self.job = job
  }

  /// One line of the window: what it is, and what it was set to.
  struct Setting: Identifiable, Equatable {
    var label: String
    var value: String
    var id: String { label }
  }

  // MARK: - The requests behind the steps

  var video: VideoRequest? {
    job.steps.lazy.compactMap { if case .downloadVideo(let r) = $0.kind { r } else { nil } }.first
  }

  var clip: ClipRequest? {
    job.steps.lazy.compactMap { if case .downloadClip(let r) = $0.kind { r } else { nil } }.first
  }

  var chat: ChatRequest? {
    job.steps.lazy.compactMap { if case .downloadChat(let r) = $0.kind { r } else { nil } }.first
  }

  var render: RenderRequest? {
    job.steps.lazy.compactMap { if case .renderChat(let r) = $0.kind { r } else { nil } }.first
  }

  var composite: CompositeRequest? {
    job.steps.lazy.compactMap { if case .composite(let r) = $0.kind { r } else { nil } }.first
  }

  // MARK: - Where it came from

  /// The address this job was created from, rebuilt.
  ///
  /// The queue never stored the link the user pasted, only the id inside the
  /// request — so this reconstructs it, which is what makes the answer
  /// something you can paste back into a browser rather than a bare number.
  var sourceURL: URL? {
    if let video { return URL(string: "https://www.twitch.tv/videos/\(video.videoID)") }
    if let clip { return URL(string: "https://clips.twitch.tv/\(clip.clipSlug)") }

    // A render-only job has no media step at all, so the chat request's id is
    // the only record of what it was rendering. All-digits means a VOD — the
    // same test upstream's `InfoHandler` branches on to decide which of two
    // completely different payloads to fetch.
    guard let identifier = chat?.videoID, !identifier.isEmpty else { return nil }
    let isVOD = identifier.allSatisfy(\.isNumber)
    return URL(string: isVOD
      ? "https://www.twitch.tv/videos/\(identifier)"
      : "https://clips.twitch.tv/\(identifier)")
  }

  /// The id or slug, for re-fetching metadata to show the thumbnail.
  var sourceIdentifier: String? {
    video?.videoID ?? clip?.clipSlug ?? chat?.videoID
  }

  // MARK: - Settings

  /// An empty quality is not a missing value — it is the choice that means
  /// "let the CLI pick source" (design §6) — so it reads as one.
  var quality: String {
    let chosen = video?.quality ?? clip?.quality
    guard let chosen, !chosen.isEmpty else { return "Best available" }
    return chosen
  }

  var trim: String {
    let start = video?.trimStart ?? chat?.trimStart
    let end = video?.trimEnd ?? chat?.trimEnd

    switch (start, end) {
    case (nil, nil): return "Whole video"
    case (let start?, let end?): return "\(Self.timecode(start)) to \(Self.timecode(end))"
    case (let start?, nil): return "From \(Self.timecode(start))"
    case (nil, let end?): return "Up to \(Self.timecode(end))"
    }
  }

  /// What this job was asked to deliver.
  ///
  /// A step with no destination was downloaded or rendered only to feed a
  /// later step and then discarded (`JobTemplate.renderInput`, and the same
  /// pattern for a composite's video and render inputs), so it is not an
  /// output — listing it would promise a file that never arrived.
  var outputs: [String] {
    var outputs: [String] = []
    if let video, video.destination != nil { outputs.append("Video") }
    if let clip, clip.destination != nil { outputs.append("Clip") }
    if let chat, chat.destination != nil {
      outputs.append("Chat (\(Self.name(of: chat.format)))")
    }
    if let render, render.destination != nil { outputs.append("Rendered chat") }
    if composite != nil { outputs.append("Video + chat") }
    return outputs
  }

  // MARK: - Where it went

  var destinationFolder: URL? {
    destinations.first?.deletingLastPathComponent()
  }

  /// Only the files that actually landed. `Step.artifact` is nil until a step
  /// succeeds, and `Reconciler` clears it again for anything still sitting
  /// inside our own workspace — but a retained composite piece lives under
  /// `Workspace.resumeRoot`, deliberately *outside* the workspace
  /// (docs/design/resume.md §3), so `Reconciler` never reaches it: retention
  /// only ever persists on a job that is *not* `.done`, which is exactly a
  /// job `Reconciler` does not stop and reconsider. A failed or cancelled
  /// composite job can therefore still have its step pointing at
  /// `resume/<jobid>/piece-N.mp4` here. Pieces are never delivered — only
  /// `.assemble`'s output is (§7) — so the composite step's artifact is
  /// excluded outright, the one step whose artifact can ever live in the
  /// retention area rather than a real destination.
  var deliveredFiles: [URL] {
    job.steps.compactMap { step in
      if case .composite = step.kind { return nil }
      return step.artifact
    }
  }

  private var destinations: [URL] {
    job.steps.compactMap { step in
      switch step.kind {
      case .downloadVideo(let r): r.destination
      case .downloadClip(let r): r.destination
      case .downloadChat(let r): r.destination
      case .renderChat(let r): r.destination
      case .composite(let r): r.destination
      case .assemble(let r): r.destination
      }
    }
  }

  // MARK: - Render settings

  /// The one thing about a composite worth reporting back: the chat column's
  /// size and rate. Everything else the old render form exposed — font,
  /// colours, emotes, outline, bitrate — is now a fixed decision the app
  /// makes, not something the user chose, so there is nothing honest left to
  /// say about it (see `IntakeModel.composedTemplate()`: intake no longer has
  /// a form for any of it). The bitrate in particular would be actively
  /// wrong to show here — `render.bitrateMbps` is the *intermediate's*, the
  /// one immediately re-encoded away, not the bitrate of the file the user
  /// actually got.
  ///
  /// Empty without both a render step and a composite step. A render step
  /// alone is reachable only through the library, never through intake, and
  /// in that case there is no video to relate its dimensions to — showing
  /// fixed defaults with nothing to explain them is worse than no section,
  /// which is the rule this property already lived by and still does.
  var renderSettings: [Setting] {
    guard let render, composite != nil else { return [] }
    return [
      Setting(
        label: "Chat column",
        value: "\(render.width) × \(render.height) at \(render.framerate) fps"),
    ]
  }

  // MARK: - Formatting

  /// `1:30` under an hour, `1:12:30` over it — the shape a video player uses,
  /// rather than a leading `0:` nobody reads.
  private static func timecode(_ duration: Duration) -> String {
    duration.components.seconds >= 3600
      ? duration.formatted(.time(pattern: .hourMinuteSecond))
      : duration.formatted(.time(pattern: .minuteSecond))
  }

  private static func name(of format: ChatFormat) -> String {
    switch format {
    case .json: "JSON"
    case .text: "Text"
    case .html: "HTML"
    }
  }
}
