import Foundation
import Observation
import OxbowKit

/// Intake state, validation, and job composition. Injected fetch and enqueue closures allow use
/// without a window or live engine.
@Observable
final class IntakeModel {

  /// A failed fetch still permits video-only downloads with an id-derived name; idle and
  /// loading disable Add.
  enum Metadata {
    case idle
    case loading
    case loaded(VideoInfo)
    case failed(String)
  }

  // MARK: - What the user types and picks

  var linkText = ""

  /// Shared output base name, initially derived from metadata and editable in the Save panel.
  var name = ""

  var output: DownloadOutput = .default

  /// CompositeGeometry scales this choice to the rendition's chat column. Only used for video
  /// with chat.
  var chatSize: ChatSize = .default

  /// Empty means best available for video-only downloads. Composites must resolve a rendition
  /// to determine geometry.
  var quality = ""

  var folder: URL?

  /// Keep the saved cap separate from this video's rendition: resolving and bucketing are not
  /// inverses. An untouched picker must preserve the seeded cap (docs/design/settings.md §3.3).
  var qualityCap: QualityCap

  /// Saving defaults requires a fresh opt-in on every intake.
  var wantsToSaveDefaults = false

  /// The stored destination was unavailable; show the fallback because it changes the
  /// disk-space estimate's volume.
  private(set) var destinationFellBack = false

  /// Persists user expansion changes, excluding transient expansion for validation errors.
  var isOptionsExpanded: Bool {
    didSet { preferences.optionsPanelIsExpanded = isOptionsExpanded }
  }

  /// Force options open to expose blocking errors without changing the stored expansion
  /// preference.
  var isOptionsEffectivelyExpanded: Bool {
    isOptionsExpanded || chatProblem != nil || compositeProblem != nil
  }

  /// Read effective expansion, write user preference. Ignore writes while an error forces the
  /// panel open so an ineffective click cannot change future intakes.
  var isOptionsEffectivelyExpandedBinding: Bool {
    get { isOptionsEffectivelyExpanded }
    set {
      guard chatProblem == nil, compositeProblem == nil else { return }
      isOptionsExpanded = newValue
    }
  }

  /// Collapsed summary uses the same clip/video labels as the expanded picker.
  var optionsSummary: String {
    let outputLabel: String
    switch (output, isClip) {
    case (.videoWithChat, true): outputLabel = "Clip + chat"
    case (.videoWithChat, false): outputLabel = "Video + chat"
    case (.video, true): outputLabel = "Clip"
    case (.video, false): outputLabel = "Video"
    }
    let folderName = folder?.lastPathComponent ?? "No folder"
    return "\(outputLabel) · \(qualityCap.label) · \(folderName)"
  }

  var isClip: Bool {
    if case .clip = target { return true }
    return false
  }

  private var preferences: Preferences

  /// Keep trim input as text so incomplete values can show validation errors instead of
  /// becoming no trim.
  var trimStartText = ""
  var trimEndText = ""

  private(set) var metadata: Metadata = .idle

  /// The id described by settled metadata. Stop using that metadata as soon as the current link
  /// differs.
  private(set) var metadataIdentifier: String?

  /// Retain the raw fetch for recording after submission, never during typing. Assign it with
  /// metadata inside the generation guard and clear them together to prevent mismatched ids and
  /// payloads.
  private(set) var lastFetch: VideoInfoFetcher.Fetched?

  /// Enqueue refusal shown while the intake remains open.
  private(set) var addFailure: String?

  // MARK: - Collaborators

  private let fetchInfo: (String) async throws -> VideoInfoFetcher.Fetched
  private let enqueue: (JobTemplate, String) async -> Void
  private let calendar: Calendar
  /// Injected filesystem check for collision tests.
  private let fileExists: (URL) -> Bool
  /// Injected capacity checks for disk-warning tests.
  private let volumeSpace: VolumeSpace
  /// Any path on the workspace volume suffices; use Application Support without duplicating
  /// workspace path construction.
  private let workspaceVolumePath: URL

  /// Injected home directory for the fallback when a watch destination no longer resolves.
  private let homeDirectory: URL

  /// Reject results from fetches superseded by a link edit.
  private var generation = 0

  init(
    fetchInfo: @escaping (String) async throws -> VideoInfoFetcher.Fetched,
    enqueue: @escaping (JobTemplate, String) async -> Void,
    calendar: Calendar = .current,
    fileExists: @escaping (URL) -> Bool = {
      FileManager.default.fileExists(atPath: $0.path)
    },
    volumeSpace: VolumeSpace = .live,
    workspaceVolumePath: URL = URL.applicationSupportDirectory,
    homeDirectory: URL = .homeDirectory,
    preferences: Preferences)
  {
    self.fetchInfo = fetchInfo
    self.enqueue = enqueue
    self.calendar = calendar
    self.fileExists = fileExists
    self.volumeSpace = volumeSpace
    self.workspaceVolumePath = workspaceVolumePath
    self.homeDirectory = homeDirectory
    self.preferences = preferences
    self.qualityCap = preferences.qualityCap
    self.output = preferences.output
    self.chatSize = preferences.chatSize
    self.folder = preferences.destination
    self.destinationFellBack = preferences.storedDestinationIsMissing
    self.isOptionsExpanded = preferences.optionsPanelIsExpanded
  }

  /// Wires live collaborators and seeds defaults from preferences.
  convenience init(
    controller: QueueController,
    calendar: Calendar = .current,
    preferences: Preferences = Preferences())
  {
    self.init(
      fetchInfo: { try await controller.fetchInfoDetailed(for: $0) },
      enqueue: { await controller.enqueue($0, title: $1) },
      calendar: calendar,
      preferences: preferences)
  }

  // MARK: - Starting over

  /// Clear per-video state on reopen and reload saved preferences. The shared Window retains
  /// this model after closing; a stale link would also prevent clipboard prefill.
  func reset() {
    linkText = ""
    name = ""
    quality = ""
    reseedFromPreferences()
    wantsToSaveDefaults = false
    isTrimExpanded = false
    trimStartText = ""
    trimEndText = ""
    metadata = .idle
    metadataIdentifier = nil
    // Clear the payload with its metadata so it cannot survive into the next intake.
    lastFetch = nil
    addFailure = nil
    // Invalidate any fetch still in flight before clearing the form.
    generation += 1
  }

  /// Reload saved settings on every open, including changes made while this Window was closed.
  /// Unlike reset(), preserve any current link, fetch, and trim state.
  func reseedFromPreferences() {
    qualityCap = preferences.qualityCap
    output = preferences.output
    chatSize = preferences.chatSize
    folder = preferences.destination
    destinationFellBack = preferences.storedDestinationIsMissing
    isOptionsExpanded = preferences.optionsPanelIsExpanded
  }

  /// Apply a watch's frozen settings before load(), which uses output and qualityCap to resolve
  /// a rendition. Validate its destination like Preferences does: an unavailable external drive
  /// must fall back visibly, not become a directory on the boot volume.
  func apply(_ pending: PendingIntake) {
    linkText = pending.archiveID
    qualityCap = pending.settings.qualityCap
    output = pending.settings.output
    chatSize = pending.settings.chatSize
    let destination = pending.settings.destination
    if fileExists(destination) {
      folder = destination
      destinationFellBack = false
    } else {
      folder = Preferences.factoryDestination(homeDirectory: homeDirectory)
      destinationFellBack = true
    }
  }

  // MARK: - The link

  var target: TwitchLink.Target? { TwitchLink.parse(linkText) }

  /// An empty field is not a validation error.
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

  /// Fetch outside the queue. Success names the job from metadata; failure uses the id or slug.
  func load() async {
    guard let target else {
      metadata = .idle
      metadataIdentifier = nil
      lastFetch = nil
      return
    }

    generation += 1
    let issued = generation
    metadata = .loading

    do {
      let fetched = try await fetchInfo(target.identifier)
      guard issued == generation else { return }
      let info = fetched.info
      // Inside the guard, with `metadata` and `metadataIdentifier`, so all
      // three always describe the same video. See `lastFetch`.
      lastFetch = fetched
      metadata = .loaded(info)
      metadataIdentifier = target.identifier
      // Resolve the saved cap against this video's renditions.
      quality = QualityLadder.resolve(
        qualityCap, in: info.qualities, forComposite: output == .videoWithChat)
      // Clear the previous video's trim, which may exceed this video's bounds.
      trimStartText = ""
      trimEndText = ""
      isTrimExpanded = false
      name = OutputNaming.baseName(
        streamer: info.streamer,
        date: info.createdAt,
        title: info.title,
        calendar: calendar,
        reservingSuffixBytes: OutputSuffix.longestBytes)
    } catch is CancellationError {
      // Cancellation may precede the replacement's generation increment; let its fetch settle
      // the state.
      return
    } catch {
      guard issued == generation else { return }
      metadata = .failed(Self.message(for: error))
      metadataIdentifier = target.identifier
      // A failed fetch must not retain the previous video's payload.
      lastFetch = nil
      quality = ""
      name = OutputNaming.sanitized(
        target.identifier, reservingSuffixBytes: OutputSuffix.longestBytes)
    }
  }

  // MARK: - Quality

  /// Without metadata, the picker offers only Best available.
  var qualities: [StreamQuality] { info?.qualities ?? [] }

  /// Update both rendition and cap on an explicit selection; resolution alone must not change
  /// the cap.
  func selectQuality(_ name: String) {
    quality = name
    guard !name.isEmpty else {
      qualityCap = .best
      return
    }
    guard let picked = qualities.first(where: { $0.name == name }),
          let bucketed = QualityLadder.bucket(picked)
    else { return }
    qualityCap = bucketed
  }

  /// Show the cap that will actually be saved when it differs from the visible rendition's size
  /// or bucket. Use qualityCap directly, including when an untouched cap resolved above its
  /// ceiling.
  var savedQualityNote: QualityCap? {
    guard !quality.isEmpty,
          let picked = qualities.first(where: { $0.name == quality }),
          let bucketed = QualityLadder.bucket(picked),
          let ceiling = bucketed.ceiling,
          picked.shortSide != ceiling || bucketed != qualityCap
    else { return nil }
    return qualityCap
  }

  /// Estimate bytes from bitrate and effective duration; nil without metadata.
  func estimatedBytes(for quality: StreamQuality) -> Int? {
    guard let duration = effectiveDuration else { return nil }
    return quality.estimatedBytes(over: duration)
  }

  /// Include pixel dimensions because rendition names may be ambiguous or malformed, especially
  /// on older clips.
  func label(for quality: StreamQuality) -> String {
    var label = quality.name
    if !quality.resolution.isEmpty { label += " · \(quality.resolution)" }
    // Zero bitrate means unknown for older clips; omit the estimate.
    guard let bytes = estimatedBytes(for: quality), bytes > 0 else { return label }
    return "\(label) — about \(Int64(bytes).formatted(.byteCount(style: .file)))"
  }

  // MARK: - Trim

  /// Trim controls are available only for parsed VOD links.
  var showsTrimOptions: Bool {
    if case .video = target { return true }
    return false
  }

  /// Presentation only: collapsing the section neither clears nor disables the trim.
  var isTrimExpanded = false

  /// VODs may trim regardless of disclosure state; clips cannot.
  private var isTrimming: Bool { showsTrimOptions }

  var trimStart: Duration? { isTrimming ? Timecode.parse(trimStartText) : nil }
  var trimEnd: Duration? { isTrimming ? Timecode.parse(trimEndText) : nil }

  /// Duration after trimming. Use this for size estimates and composite progress so they
  /// describe the selected span.
  var effectiveDuration: Duration? {
    guard let fullDuration = info?.duration else { return nil }
    return (trimEnd ?? fullDuration) - (trimStart ?? .zero)
  }

  /// Keep the active range visible in the collapsed header.
  var trimSummary: String? {
    guard isTrimming, !trimIsInvalid else { return nil }
    switch (trimStart, trimEnd) {
    case (nil, nil): return nil
    case (let start?, let end?): return "\(Timecode.format(start)) – \(Timecode.format(end))"
    case (let start?, nil): return "from \(Timecode.format(start))"
    case (nil, let end?): return "up to \(Timecode.format(end))"
    }
  }

  /// Reject malformed times, reversed ranges, and out-of-bounds trims before invoking the CLI.
  var trimIsInvalid: Bool {
    guard isTrimming else { return false }
    if !Timecode.isBlankOrValid(trimStartText) || !Timecode.isBlankOrValid(trimEndText) {
      return true
    }
    if let start = trimStart, let end = trimEnd, end <= start { return true }
    if let total = info?.duration {
      if let start = trimStart, start >= total { return true }
      if let end = trimEnd, end > total { return true }
    }
    return false
  }

  // MARK: - Composing the job

  /// Translate the picker name through StreamQuality.commandLineValue only when building a
  /// request. Fall back to the stored value when no rendition matches.
  private var commandLineQuality: String {
    qualities.first(where: { $0.name == quality })?.commandLineValue ?? quality
  }

  /// Resolve Best available to a rendition with usable composite geometry. Honour explicit
  /// picks even if unparseable: compositeProblem must explain the refusal instead of silently
  /// substituting another quality.
  private var compositeQuality: StreamQuality? {
    if !quality.isEmpty, let named = qualities.first(where: { $0.name == quality }) {
      return named
    }
    return qualities.first { CompositeGeometry(quality: $0) != nil }
  }

  /// Explain missing rendition geometry for video with chat. Older clips may lack dimensions;
  /// odd dimensions are accepted and rounded down to even by CompositeGeometry.
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

  /// Refuse composites without metadata or a clip's source-broadcast chat; video-only remains
  /// available. Otherwise the media download could finish as an undelivered intermediate behind
  /// a failed chat step.
  var chatProblem: String? {
    guard output == .videoWithChat else { return nil }

    if metadataFailure != nil {
      return """
        Without this video's details, Oxbow cannot size the chat column or \
        time the encode. Choose "Video" to download the video itself.
        """
    }

    guard let info, !info.hasDownloadableChat else { return nil }
    return """
      This clip's original broadcast is no longer on Twitch, so its chat \
      cannot be downloaded. Choose "Video" to download the clip itself.
      """
  }

  /// Do not save video-only as a preference when chat is unavailable for this video. Check
  /// metadata failure and missing chat independently of the current output, since switching to
  /// video-only clears chatProblem.
  var withholdsOutputFromSave: Bool {
    if metadataFailure != nil { return true }
    guard let info else { return false }
    return !info.hasDownloadableChat
  }

  /// Do not save chat size when its picker is hidden by video-only output.
  var withholdsChatSizeFromSave: Bool { output != .videoWithChat }

  /// True once *this link's* fetch has settled either way. `.failed` counts:
  /// the sheet stays usable, with a name derived from the id or slug.
  var hasSettledMetadata: Bool {
    guard describesCurrentLink else { return false }
    switch metadata {
    case .loaded, .failed: return true
    case .idle, .loading: return false
    }
  }

  /// Shared collision check for the warning and replacesExistingFile. Wait for settled metadata
  /// so the name is final. Do not gate on canAdd: composedTemplate() reads this property and
  /// would recurse.
  var destinationCollision: URL? {
    guard hasSettledMetadata, let folder else { return nil }
    let destination = folder.appending(path: outputBaseName + OutputSuffix.video)
    return fileExists(destination) ? destination : nil
  }

  // MARK: - Not enough room

  /// Insufficient volume capacity with an optional lower-quality remedy.
  struct SpaceWarning: Equatable {
    var needed: Int64
    var available: Int64
    var volumeName: String
    /// A lower rendition that would actually fit, or nil when none would.
    var remedy: Remedy?

    struct Remedy: Equatable {
      var qualityName: String
      var needed: Int64
    }
  }

  /// Advisory estimate; never gates Add. Recompute from settled metadata and current volume
  /// capacity as quality, trim, and output change. See docs/design/disk-preflight.md §3.2.
  var spaceWarning: SpaceWarning? {
    guard hasSettledMetadata,
          let folder,
          let duration = effectiveDuration,
          let quality = estimatedQuality,
          let shortfall = shortfall(for: quality, over: duration, in: folder)
    else { return nil }

    return SpaceWarning(
      needed: shortfall.needed,
      available: shortfall.available,
      volumeName: shortfall.volumeName,
      remedy: remedy(under: quality, over: duration, in: folder))
  }

  /// Estimate the selected rendition, resolving Best available separately for composites and
  /// plain video.
  private var estimatedQuality: StreamQuality? {
    switch output {
    case .videoWithChat: return compositeQuality
    case .video: return qualities.first { $0.name == quality } ?? qualities.first
    }
  }

  private func estimate(for quality: StreamQuality, over duration: Duration) -> SpaceEstimate {
    SpaceEstimate(
      quality: quality,
      duration: duration,
      // Exclude render and composite space entirely for plain video.
      composite: output == .videoWithChat ? CompositeGeometry(quality: quality) : nil)
  }

  private func shortfall(
    for quality: StreamQuality,
    over duration: Duration,
    in folder: URL) -> VolumeSpace.Shortfall?
  {
    let estimate = estimate(for: quality, over: duration)
    return volumeSpace.shortfall(
      needingWorkspace: estimate.total,
      delivered: estimate.delivered,
      workspace: workspaceVolumePath,
      destination: folder)
  }

  /// Find the highest lower rendition that passes the same capacity check.
  private func remedy(
    under quality: StreamQuality,
    over duration: Duration,
    in folder: URL) -> SpaceWarning.Remedy?
  {
    let current = estimate(for: quality, over: duration).total
    let fitting = qualities
      .filter { $0.name != quality.name }
      .map { (candidate: $0, needed: estimate(for: $0, over: duration).total) }
      .filter { $0.needed < current }
      .filter { shortfall(for: $0.candidate, over: duration, in: folder) == nil }

    guard let best = fitting.max(by: { $0.needed < $1.needed }) else { return nil }
    return SpaceWarning.Remedy(qualityName: best.candidate.name, needed: best.needed)
  }

  var canAdd: Bool { composedTemplate() != nil }

  /// Sanitized base name with space reserved for the longest output suffix, even if the output
  /// choice changes later.
  var outputBaseName: String {
    OutputNaming.sanitized(name, reservingSuffixBytes: OutputSuffix.longestBytes)
  }

  /// Composes the job, or nil when Add must be disabled.
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
          quality: commandLineQuality,
          trimStart: trimStart,
          trimEnd: trimEnd,
          destination: destination(OutputSuffix.video)))
      case .clip(let slug):
        media = .clip(ClipRequest(
          clipSlug: slug,
          quality: commandLineQuality,
          destination: destination(OutputSuffix.video)))
      }

    case .videoWithChat:
      // Keep the chat refusal in composition as well as its UI explanation.
      guard chatProblem == nil else { return nil }

      // Require geometry and use the trimmed effectiveDuration for composite progress and ETA.
      guard let selected = compositeQuality,
            let geometry = CompositeGeometry(quality: selected),
            let duration = effectiveDuration
      else { return nil }

      // Only the final composite is delivered; media and render steps remain intermediates.
      // Chat requests accept both VOD ids and clip slugs.
      switch target {
      case .video(let id):
        media = .video(VideoRequest(
          videoID: id, quality: selected.commandLineValue,
          trimStart: trimStart, trimEnd: trimEnd, destination: nil))
        chat = ChatRequest(
          videoID: id, trimStart: trimStart, trimEnd: trimEnd,
          format: .json, destination: nil)
      case .clip(let slug):
        media = .clip(ClipRequest(
          clipSlug: slug, quality: selected.commandLineValue, destination: nil))
        chat = ChatRequest(videoID: slug, format: .json, destination: nil)
      }
      render = RenderRequest(
        width: geometry.chatWidth,
        height: geometry.videoHeight,
        framerate: geometry.chatFramerate,
        fontSize: geometry.fontSize(for: chatSize),
        // High-bitrate intermediate limits loss before the final re-encode; see
        // docs/design/composite-quality.md.
        bitrateMbps: 12,
        destination: nil)
      composite = CompositeRequest(
        framerate: geometry.videoFramerate,
        duration: duration,
        destination: destination(OutputSuffix.video))
    }

    return JobTemplate(
      media: media,
      chat: chat,
      render: render,
      composite: composite,
      replacesExistingFile: destinationCollision != nil)
  }

  /// Await enqueue before reporting success. On refusal, keep the intake open with addFailure.
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

  /// Save only after successful enqueue; cancellation and refusal must not persist defaults.
  func saveDefaultsIfRequested() {
    guard wantsToSaveDefaults else { return }
    // Capture first-save state before any setter calls Preferences.recordSave().
    let isFirstSave = !preferences.hasSavedDefaults
    if let folder { preferences.destination = folder }
    if !withholdsChatSizeFromSave { preferences.chatSize = chatSize }
    if !withholdsOutputFromSave { preferences.output = output }
    // Save the retained cap, not a bucket re-derived from this video's resolved rendition.
    preferences.qualityCap = qualityCap
    // Collapse only on the first save; preserve later user expansion choices.
    if isFirstSave { isOptionsExpanded = false }
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

/// Filename suffix shared by plain video and composites.
nonisolated enum OutputSuffix {
  static let video = ".mp4"

  /// Longest output suffix in UTF-8 bytes.
  static let longestBytes: Int = {
    let all = [video]
    return all.map(\.utf8.count).max() ?? 0
  }()
}

/// `nonisolated` to match `TwitchLink`: a pure mapping, callable from a synchronous test.
nonisolated extension TwitchLink.Target {
  /// Both info and chatdownload accept a VOD id or clip slug as --id.
  var identifier: String {
    switch self {
    case .video(let id): id
    case .clip(let slug): slug
    }
  }
}
