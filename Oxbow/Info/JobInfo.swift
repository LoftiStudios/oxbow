import Foundation
import OxbowKit

/// Derives display values from persisted step requests. `nonisolated` allows synchronous use
/// outside the app's default main actor.
nonisolated struct JobInfo {
  let job: Job

  init(job: Job) {
    self.job = job
  }

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

  /// Reconstruct the source URL from the request's stored identifier.
  var sourceURL: URL? {
    if let video { return URL(string: "https://www.twitch.tv/videos/\(video.videoID)") }
    if let clip { return URL(string: "https://clips.twitch.tv/\(clip.clipSlug)") }

    // Fall back to the chat request when there is no media step. Upstream treats all-digit
    // identifiers as VODs.
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

  /// An empty quality asks the CLI to select source.
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

  /// Only steps with destinations deliver outputs; intermediate artifacts are excluded.
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

  /// Uses Job.deliveredFiles to exclude workspace intermediates, even when their steps are
  /// done.
  var deliveredFiles: [URL] { job.deliveredFiles }

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

  /// Report the composite chat column's dimensions and rate. Render bitrate describes the
  /// intermediate, not the delivered file. Omit the section without both render and composite
  /// steps.
  var renderSettings: [Setting] {
    guard let render, composite != nil else { return [] }
    return [
      Setting(
        label: "Chat column",
        value: "\(render.width) × \(render.height) at \(render.framerate) fps"),
    ]
  }

  // MARK: - Formatting

  /// Player-style timecode: m:ss below an hour, h:mm:ss above.
  private static func timecode(_ duration: Duration) -> String {
    VideoLength.timecode(duration)
  }

  private static func name(of format: ChatFormat) -> String {
    switch format {
    case .json: "JSON"
    case .text: "Text"
    case .html: "HTML"
    }
  }
}
