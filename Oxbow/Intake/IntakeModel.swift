import Foundation
import Observation
import OxbowKit

/// Everything the intake sheet knows and every decision it makes.
///
/// The sheet's rules are not presentation: which outputs are legal, what each
/// one is called, where it lands, and whether Add may fire at all come from
/// the design doc (§2 intake, §4 filenames, §6 quality, §8 clips). They live
/// here so they can be tested without a window, and `IntakeSheet` is left as
/// a rendering of this type.
///
/// The two collaborators are closures rather than a `QueueController` so a
/// test can supply a metadata failure or capture an enqueued template without
/// standing up an engine; `init(controller:)` wires the real ones.
@Observable
final class IntakeModel {

  /// Where the one metadata fetch per link has got to.
  ///
  /// `.failed` is a usable state, not a dead end: the name falls back to the
  /// id or slug and the sheet still composes a job (design doc §3 — the fetch
  /// exists to name files and offer qualities, and both have an answer
  /// without it). Only `.idle` and `.loading` disable Add.
  enum Metadata {
    case idle
    case loading
    case loaded(VideoInfo)
    case failed(String)
  }

  // MARK: - What the user types and picks

  var linkText = ""

  /// The shared base name for this job's outputs, pre-filled from the video's
  /// own metadata and then the user's to edit.
  var name = ""

  /// The three toggles from §2. `isDownloadingMedia` covers a VOD and a clip
  /// alike — which one it means is the pasted link's business, not a fourth
  /// switch's.
  var isDownloadingMedia = true
  var isDownloadingChat = false
  var isRenderingChat = false

  var chatFormat: ChatFormat = .json

  /// The empty string means "best available" — the behaviour proven against
  /// the real CLI, which selects source when `-q` is absent (design doc §6).
  var quality = ""

  var folder: URL?

  /// Trim times as typed, parsed by `Timecode`. Kept as text rather than
  /// `Duration?` so a half-typed value is a visible error rather than
  /// silently reading as no trim at all.
  var trimStartText = ""
  var trimEndText = ""

  /// The render form's own state. Task 9's `RenderOptionsView` binds straight
  /// into this; `composedTemplate()` copies it and overwrites the
  /// destination, so `placeholderDestination` is never read back out.
  var renderOptions = RenderRequest(destination: IntakeModel.placeholderDestination)

  private(set) var metadata: Metadata = .idle

  /// The id or slug the settled `metadata` actually describes.
  ///
  /// Metadata outlives the link it was fetched for — the user can paste
  /// another one at any point — and everything derived from it (the name, the
  /// quality list, and Add itself) has to stop trusting it the moment the two
  /// disagree, or a job gets composed for one video out of another's details.
  private(set) var metadataIdentifier: String?

  /// Set when Add refused. Only reachable if `canAdd` and
  /// `composedTemplate()` ever disagreed, which they cannot — but a sheet
  /// that closes on a job that was never composed is exactly the silent
  /// failure this whole path exists to avoid, so the refusal says so out loud
  /// instead of dismissing.
  private(set) var addFailure: String?

  // MARK: - Collaborators

  private let fetchInfo: (String) async throws -> VideoInfo
  private let enqueue: (JobTemplate, String) async -> Void
  private let calendar: Calendar

  /// Distinguishes the fetch in flight from one the user has already
  /// superseded by editing the link. Without it a slow fetch for the previous
  /// link lands last and names the job after the wrong video.
  private var generation = 0

  init(
    fetchInfo: @escaping (String) async throws -> VideoInfo,
    enqueue: @escaping (JobTemplate, String) async -> Void,
    calendar: Calendar = .current)
  {
    self.fetchInfo = fetchInfo
    self.enqueue = enqueue
    self.calendar = calendar
  }

  convenience init(controller: QueueController, calendar: Calendar = .current) {
    self.init(
      fetchInfo: { try await controller.fetchInfo(for: $0) },
      enqueue: { await controller.enqueue($0, title: $1) },
      calendar: calendar)
  }

  // MARK: - The link

  var target: TwitchLink.Target? { TwitchLink.parse(linkText) }

  /// Something was typed and it is not a Twitch address. An empty field is
  /// not an error, it is the starting state.
  var isLinkUnrecognized: Bool {
    !linkText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && target == nil
  }

  var isLoadingMetadata: Bool {
    if case .loading = metadata { return true }
    return false
  }

  var metadataFailure: String? {
    guard describesCurrentLink, case .failed(let message) = metadata else { return nil }
    return message
  }

  var info: VideoInfo? {
    guard describesCurrentLink, case .loaded(let info) = metadata else { return nil }
    return info
  }

  /// Whether the settled metadata is this link's, rather than the one it
  /// replaced.
  private var describesCurrentLink: Bool {
    guard let identifier = metadataIdentifier, let target else { return false }
    return identifier == target.identifier
  }

  /// Fetches the pasted link's metadata, outside the queue (design doc §3),
  /// and settles into `.loaded` or `.failed`. Both settled states fill in a
  /// name — from the video's own metadata, or from the id or slug when the
  /// fetch failed.
  func load() async {
    guard let target else {
      metadata = .idle
      metadataIdentifier = nil
      return
    }

    generation += 1
    let issued = generation
    metadata = .loading

    do {
      let info = try await fetchInfo(target.identifier)
      guard issued == generation else { return }
      metadata = .loaded(info)
      metadataIdentifier = target.identifier
      // A different video: whatever quality was picked for the last one is
      // not necessarily on offer for this one.
      quality = ""
      name = OutputNaming.baseName(
        streamer: info.streamer,
        date: info.createdAt,
        title: info.title,
        calendar: calendar,
        reservingSuffixBytes: OutputSuffix.longestBytes)
    } catch {
      guard issued == generation else { return }
      metadata = .failed(Self.message(for: error))
      metadataIdentifier = target.identifier
      quality = ""
      name = OutputNaming.sanitized(
        target.identifier, reservingSuffixBytes: OutputSuffix.longestBytes)
    }
  }

  // MARK: - Quality

  /// Empty until metadata arrives, and empty after a failure — which the
  /// picker renders as nothing but "Best available", the same thing an empty
  /// `quality` means to the CLI.
  var qualities: [StreamQuality] { info?.qualities ?? [] }

  /// `bitsPerSecond x duration`, matching what the WPF app offers (§6). Nil
  /// without metadata, because there is no duration to multiply by — a
  /// zero would read as a real estimate of nothing.
  func estimatedBytes(for quality: StreamQuality) -> Int? {
    guard let info else { return nil }
    return quality.estimatedBytes(over: info.duration)
  }

  // MARK: - Trim

  /// Clips have no trim options, so they are hidden rather than disabled
  /// (design doc §8). Nothing to hide before a link parses, either.
  var showsTrimOptions: Bool {
    if case .video = target { return true }
    return false
  }

  var trimStart: Duration? { showsTrimOptions ? Timecode.parse(trimStartText) : nil }
  var trimEnd: Duration? { showsTrimOptions ? Timecode.parse(trimEndText) : nil }

  /// A typed trim time that is neither empty nor a time, or an end at or
  /// before the start. Either would reach the CLI as an argument that fails
  /// minutes into a download, so Add refuses first.
  var trimIsInvalid: Bool {
    guard showsTrimOptions else { return false }
    if !Timecode.isBlankOrValid(trimStartText) || !Timecode.isBlankOrValid(trimEndText) {
      return true
    }
    if let start = trimStart, let end = trimEnd, end <= start { return true }
    return false
  }

  // MARK: - Composing the job

  var hasSelectedOutput: Bool { isDownloadingMedia || isDownloadingChat || isRenderingChat }

  /// True once *this link's* fetch has settled either way. `.failed` counts:
  /// the sheet stays usable, with a name derived from the id or slug.
  var hasSettledMetadata: Bool {
    guard describesCurrentLink else { return false }
    switch metadata {
    case .loaded, .failed: return true
    case .idle, .loading: return false
    }
  }

  /// Exactly the condition under which `composedTemplate()` returns
  /// something — one definition, so the button's enabled state and what Add
  /// can actually build cannot drift apart.
  var canAdd: Bool { composedTemplate() != nil }

  /// The name every output of this job shares, sanitized and with room
  /// reserved for the longest suffix any of them can take.
  ///
  /// The reservation is over *every* suffix, not just the selected outputs':
  /// the toggles change after the name is derived, and a base name that has
  /// to be recomputed when Chat is switched on is a base name the video and
  /// its chat sibling can disagree about (design doc §4).
  var outputBaseName: String {
    OutputNaming.sanitized(name, reservingSuffixBytes: OutputSuffix.longestBytes)
  }

  /// The job this sheet would add, or `nil` if it is not in a state to add
  /// one. Every disabled-Add rule in the design doc is a `guard` here.
  func composedTemplate() -> JobTemplate? {
    guard
      let target,
      let folder,
      hasSelectedOutput,
      hasSettledMetadata,
      !trimIsInvalid
    else { return nil }

    let base = outputBaseName
    func destination(_ suffix: String) -> URL { folder.appending(path: base + suffix) }

    var media: JobTemplate.Media?
    if isDownloadingMedia {
      switch target {
      case .video(let id):
        media = .video(VideoRequest(
          videoID: id,
          quality: quality,
          trimStart: trimStart,
          trimEnd: trimEnd,
          destination: destination(OutputSuffix.video)))
      case .clip(let slug):
        media = .clip(ClipRequest(
          clipSlug: slug,
          quality: quality,
          destination: destination(OutputSuffix.video)))
      }
    }

    // A render needs a chat file to render, so it implies the download even
    // with the Chat toggle off. The toggle decides only whether that file is
    // *delivered*: with Chat off the destination is `nil`, which is how the
    // queue already says "stays in the workspace and is discarded with it" —
    // the open question in task-queue.md §10, answered by the toggle rather
    // than by a new concept (design doc §2).
    //
    // Built here rather than left to `JobTemplate`'s implied request, which
    // seeds its id from the media: with Media off and Render on there is no
    // media to seed from, and the implied request would carry an empty id —
    // a job that runs and downloads nothing.
    var chat: ChatRequest?
    if isDownloadingChat || isRenderingChat {
      chat = ChatRequest(
        videoID: target.identifier,
        trimStart: trimStart,
        trimEnd: trimEnd,
        format: chatFormat,
        destination: isDownloadingChat ? destination(OutputSuffix.chat(chatFormat)) : nil)
    }

    var render: RenderRequest?
    if isRenderingChat {
      render = renderOptions
      render?.destination = destination(OutputSuffix.render)
    }

    // Unreachable given `hasSelectedOutput`, but a template with no parts
    // makes a job with no steps: something that appears in the queue, does
    // nothing, and explains nothing.
    guard media != nil || chat != nil || render != nil else { return nil }

    return JobTemplate(media: media, chat: chat, render: render)
  }

  /// Adds the job. Returns whether it landed, so the sheet dismisses on a
  /// fact rather than on a hope: `QueueController.enqueue` is awaited all the
  /// way into the engine, and a refusal leaves the sheet open with
  /// `addFailure` saying why.
  @discardableResult
  func add() async -> Bool {
    guard let template = composedTemplate() else {
      addFailure = """
        Oxbow could not build that download. Check the link, the outputs, and \
        the destination folder.
        """
      return false
    }
    addFailure = nil
    await enqueue(template, outputBaseName)
    return true
  }

  // MARK: - Failure text

  private static func message(for error: Error) -> String {
    switch error {
    case VideoInfoFetchError.helperFailed(_, let standardError) where !standardError.isEmpty:
      return "Oxbow could not read that video's details: \(firstLine(of: standardError))"
    case VideoInfoFetchError.helperFailed:
      return "Oxbow could not read that video's details. The link may be wrong, or the video private."
    case VideoInfoFetchError.unparseableOutput:
      return "Oxbow could not make sense of that video's details."
    default:
      return "Oxbow could not read that video's details: \(error.localizedDescription)"
    }
  }

  /// The CLI's useful sentence is the first line; the rest is a stack trace.
  private static func firstLine(of text: String) -> String {
    text
      .split(separator: "\n", omittingEmptySubsequences: true)
      .first
      .map { $0.trimmingCharacters(in: .whitespaces) } ?? text
  }

  /// Overwritten by `composedTemplate()` before it reaches a job. It exists
  /// only because `RenderRequest.destination` is non-optional and the render
  /// form has to have something to bind to before a folder is chosen.
  private static let placeholderDestination = URL(filePath: "/dev/null")
}

/// The per-output suffixes from the design doc, §4.
nonisolated enum OutputSuffix {
  static let video = ".mp4"
  static let render = " - chat.mp4"

  static func chat(_ format: ChatFormat) -> String {
    switch format {
    case .json: " - chat.json"
    case .text: " - chat.txt"
    case .html: " - chat.html"
    }
  }

  /// The longest suffix any output can take, in UTF-8 bytes, computed from
  /// the suffixes themselves — a literal would quietly stop being the longest
  /// the first time one of them grows.
  static let longestBytes: Int = {
    let all = [video, render, chat(.json), chat(.text), chat(.html)]
    return all.map(\.utf8.count).max() ?? 0
  }()
}

/// Parses the trim times the user types.
///
/// Accepts `ss`, `mm:ss`, and `hh:mm:ss`, which is what people paste out of a
/// Twitch timestamp. Everything else is rejected rather than coerced: a
/// silently-misread trim produces a download of the wrong part of a VOD,
/// which looks like a successful job.
nonisolated enum Timecode {

  static func parse(_ text: String) -> Duration? {
    let trimmed = text.trimmingCharacters(in: .whitespaces)
    guard !trimmed.isEmpty else { return nil }

    let parts = trimmed.split(separator: ":", omittingEmptySubsequences: false)
    guard parts.count <= 3 else { return nil }

    var total = 0
    for (index, part) in parts.enumerated() {
      // `Int(_:)` alone would accept "+5", " 5", and non-ASCII digits.
      guard !part.isEmpty, part.allSatisfy({ $0.isASCII && $0.isNumber }), let value = Int(part)
      else { return nil }
      // Only the leading field may exceed 59: "90" is a minute and a half,
      // but "1:90" is not a time anybody means.
      if index > 0 && value > 59 { return nil }
      total = total * 60 + value
    }
    return .seconds(total)
  }

  /// An empty field means "no trim", which is valid. Anything else has to
  /// parse.
  static func isBlankOrValid(_ text: String) -> Bool {
    text.trimmingCharacters(in: .whitespaces).isEmpty || parse(text) != nil
  }
}

extension TwitchLink.Target {
  /// What the CLI's `--id` takes for either kind: upstream's `chatdownload`
  /// and `info` both accept a VOD id and a clip slug in the same parameter
  /// (design doc §8).
  var identifier: String {
    switch self {
    case .video(let id): id
    case .clip(let slug): slug
    }
  }
}
