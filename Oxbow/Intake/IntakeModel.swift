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

  /// What the user gets. Deliberately two choices rather than three
  /// independent toggles: a chat render in isolation has little use, and the
  /// composite is what makes it worth producing at all. See
  /// docs/design/compositing.md §3.
  enum Output: CaseIterable, Hashable {
    case video
    case videoWithChat
  }

  var output: Output = .video

  /// The empty string means "best available" — the behaviour proven against
  /// the real CLI, which selects source when `-q` is absent (design doc §6).
  /// Video-only keeps that behaviour; a composite cannot leave it unresolved
  /// (see `compositeQuality`) because the chat column's height must equal the
  /// video's.
  var quality = ""

  var folder: URL?

  /// Trim times as typed, parsed by `Timecode`. Kept as text rather than
  /// `Duration?` so a half-typed value is a visible error rather than
  /// silently reading as no trim at all.
  var trimStartText = ""
  var trimEndText = ""

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
    // Seeded here rather than in the designated init on purpose: the rule that
    // `composedTemplate()` refuses without a destination is a real one worth
    // testing, and a default baked into every model would make it unreachable.
    // This is the app's starting value, not the model's invariant.
    folder = Self.defaultDestination
  }

  /// `~/Downloads`, or nil if the system has no such folder.
  ///
  /// The point is that a freshly opened window is already addable: paste a
  /// link, press Add, and the file lands somewhere sensible. Before this,
  /// Add stayed disabled until you clicked Choose… — on every download,
  /// every time — which made the common case pay for the rare one.
  ///
  /// Not persisted as "last used" yet. That is the better long-run behaviour
  /// and a small addition, but it is a different decision: a folder you
  /// picked once for one video silently becoming the default for everything
  /// afterwards is a choice to make deliberately, not a side effect of this
  /// one.
  static var defaultDestination: URL? {
    try? FileManager.default.url(
      for: .downloadsDirectory, in: .userDomainMask, appropriateFor: nil, create: false)
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
    } catch is CancellationError {
      // The user typed on and this fetch was superseded. Not a failure to
      // report: the replacement is already on its way and will settle the
      // state, and `generation` cannot be relied on to hide this — the
      // replacement has not necessarily incremented it yet.
      return
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

  /// One row of the quality picker.
  ///
  /// The pixel size is shown alongside the name because the name does not
  /// always imply it. A VOD's `480p30` is 852x480, not 854 or 640; a clip's
  /// name comes from upstream's `{quality}p{framerate}` and degenerates to
  /// things like `720p0` on older clips, where the resolution is the only
  /// legible part. And when a clip carries no bitrate there is no size
  /// estimate at all, so without it the row would be a bare `720p0-1`.
  ///
  /// Here rather than in the view so it can be tested, like every other rule
  /// the sheet obeys.
  func label(for quality: StreamQuality) -> String {
    var label = quality.name
    if !quality.resolution.isEmpty { label += " · \(quality.resolution)" }
    // `bytes == 0` is not an estimate of nothing, it is the absence of one:
    // older clips carry `bitrate: 0` for every rendition, and "about Zero KB"
    // reads as a fact rather than as a missing input.
    guard let bytes = estimatedBytes(for: quality), bytes > 0 else { return label }
    // "about", because it is bitrate x duration and nothing more (§6).
    return "\(label) — about \(Int64(bytes).formatted(.byteCount(style: .file)))"
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

  /// The quality a composite will actually download. "Best available" leaves
  /// the resolution unknown, which is fatal when the chat's height must equal
  /// the video's — so a composite resolves it to a concrete rendition and
  /// passes it explicitly. Video-only keeps today's behaviour, where empty
  /// means the CLI picks.
  ///
  /// **An explicit pick is honoured even when it cannot be composited — never
  /// silently swapped for one that can.** `docs/design/chat-and-render.md`
  /// already records the cost of that shortcut: `-q 1080p60-Portrait` on the
  /// real CLI silently downloads the landscape rendition instead, exit 0, no
  /// warning — handing someone the wrong video and calling it a success,
  /// which is worse than either honest outcome. So this only falls back to
  /// the first rendition `CompositeGeometry` can parse when `quality` is
  /// empty, meaning the user asked for "best available" and never named a
  /// rendition to begin with. An explicit pick that turns out unparseable
  /// (`CompositeGeometry.init?(quality:)` fails for a rendition with no pixel
  /// width — see `compositeProblem`) is returned as-is; `composedTemplate()`
  /// then refuses rather than substituting, and `compositeProblem` is what
  /// says why.
  private var compositeQuality: StreamQuality? {
    if !quality.isEmpty, let named = qualities.first(where: { $0.name == quality }) {
      return named
    }
    return qualities.first { CompositeGeometry(quality: $0) != nil }
  }

  /// Why `.videoWithChat` cannot be added right now, or nil when it can (or
  /// when `.video` is selected, where no quality decision is even made).
  ///
  /// This is only reachable for a clip. A VOD's `VideoInfo.parseQualities`
  /// skips any m3u8 variant with no `RESOLUTION` attribute outright, so every
  /// `StreamQuality` it emits already has one. A clip's `clipResolution` has
  /// no such filter — Twitch does not always backfill dimensions on an older
  /// clip's rendition, and that rendition still reaches the picker with an
  /// empty `resolution`. Picking exactly that one is a silent dead end
  /// without this: `compositeQuality` honours the explicit pick (by design,
  /// see its doc comment), `CompositeGeometry` then fails to parse it, and
  /// `composedTemplate()` returns nil with nothing on screen explaining why.
  var compositeProblem: String? {
    guard output == .videoWithChat,
          let selected = compositeQuality,
          CompositeGeometry(quality: selected) == nil
    else { return nil }
    return """
      Twitch never recorded pixel dimensions for \(selected.name), so its \
      chat column cannot be sized to match. Pick another quality.
      """
  }

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
  /// The reservation is over the suffix regardless of the current `output`:
  /// that setting can change after the name is derived, and a base name that
  /// had to be recomputed when it did would be a base name a rename could
  /// disagree with itself about (design doc §4).
  var outputBaseName: String {
    OutputNaming.sanitized(name, reservingSuffixBytes: OutputSuffix.longestBytes)
  }

  /// The job this sheet would add, or `nil` if it is not in a state to add
  /// one. Every disabled-Add rule in the design doc is a `guard` here.
  func composedTemplate() -> JobTemplate? {
    guard
      let target,
      let folder,
      hasSettledMetadata,
      !trimIsInvalid
    else { return nil }

    let base = outputBaseName
    func destination(_ suffix: String) -> URL { folder.appending(path: base + suffix) }

    var media: JobTemplate.Media?
    var chat: ChatRequest?
    var render: RenderRequest?
    var composite: CompositeRequest?

    switch output {
    case .video:
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

    case .videoWithChat:
      // The composite needs a concrete rendition to derive its geometry from
      // (see `compositeQuality`), and a duration to report FFmpeg progress
      // against. Neither is available without settled metadata.
      guard let selected = compositeQuality,
            let geometry = CompositeGeometry(quality: selected),
            let duration = info?.duration
      else { return nil }

      // One file out: the media and the render are intermediates, so neither
      // gets a destination of its own — only the composite does, below.
      //
      // Clips get the same two choices as VODs (design doc §3). A clip has no
      // trim, and `chatdownload --id` takes a slug as readily as a VOD id, so
      // the only difference is which request type carries the identifier.
      switch target {
      case .video(let id):
        media = .video(VideoRequest(
          videoID: id, quality: selected.name,
          trimStart: trimStart, trimEnd: trimEnd, destination: nil))
        chat = ChatRequest(
          videoID: id, trimStart: trimStart, trimEnd: trimEnd,
          format: .json, destination: nil)
      case .clip(let slug):
        media = .clip(ClipRequest(
          clipSlug: slug, quality: selected.name, destination: nil))
        chat = ChatRequest(videoID: slug, format: .json, destination: nil)
      }
      render = RenderRequest(
        width: geometry.chatWidth,
        height: geometry.videoHeight,
        framerate: geometry.chatFramerate,
        // Transient and immediately re-encoded, so encode it well: at the old
        // 3 Mbps default the composite carried two generations of lossy H.264
        // over text on flat backgrounds. VideoToolbox's speed is independent
        // of bitrate, so this costs only workspace disk.
        bitrateMbps: 12,
        destination: nil)
      composite = CompositeRequest(
        framerate: geometry.videoFramerate,
        bitrateMbps: max(selected.bitsPerSecond / 1_000_000, 6),
        duration: duration,
        destination: destination(OutputSuffix.video))
    }

    return JobTemplate(media: media, chat: chat, render: render, composite: composite)
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

}

/// The per-output suffix from the design doc, §4.
///
/// One case now, not five: intake no longer offers a bare chat download or a
/// bare chat render (see `IntakeModel.Output`), so the video suffix — shared
/// by a plain video and a composite alike, since a composite replaces the
/// video it stacks rather than accompanying it — is the only one left.
nonisolated enum OutputSuffix {
  static let video = ".mp4"

  /// The longest suffix any output can take, in UTF-8 bytes, computed from
  /// the suffixes themselves — a literal would quietly stop being the longest
  /// the first time one of them grows.
  static let longestBytes: Int = {
    let all = [video]
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
      // `Int(_:)` alone would accept "+5", " 5", and non-ASCII digits — and
      // returns nil for a run of digits too long for `Int`, which is the
      // first half of the overflow guard below.
      guard !part.isEmpty, part.allSatisfy({ $0.isASCII && $0.isNumber }), let value = Int(part)
      else { return nil }
      // Only the leading field may exceed 59: "90" is a minute and a half,
      // but "1:90" is not a time anybody means.
      if index > 0 && value > 59 { return nil }
      // Reported rather than trapping. Swift traps on integer overflow, so a
      // plain `total * 60 + value` turns a long number pasted into the trim
      // field into a crash — no privileged input required, just a text field
      // and a fat thumb. Too big to be a time is invalid input like any
      // other, and the sheet already refuses invalid input gracefully.
      let (scaled, didScaleOverflow) = total.multipliedReportingOverflow(by: 60)
      guard !didScaleOverflow else { return nil }
      let (sum, didSumOverflow) = scaled.addingReportingOverflow(value)
      guard !didSumOverflow else { return nil }
      total = sum
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
