import Foundation
import Testing
import OxbowKit
@testable import Oxbow

@MainActor
@Suite("Intake model")
struct IntakeModelTests {

  // MARK: - The default destination

  /// Add used to be disabled on a freshly opened window until you clicked
  /// Choose…, every time, on every download. A Twitch VOD going to
  /// ~/Downloads is the overwhelmingly common case, so it is the default and
  /// Choose… is the override.
  @Test func offersTheDownloadsFolderAsTheDefaultDestination() throws {
    let destination = try #require(IntakeModel.defaultDestination)
    #expect(destination.lastPathComponent == "Downloads")
  }

  /// The default is applied where the window builds its model, not inside the
  /// rules: `composedTemplate()` still refuses without a folder, and the tests
  /// that assert that refusal build a model with none. A default baked into
  /// every `IntakeModel` would make that rule untestable.
  @Test func aModelBuiltWithoutADestinationStillHasNone() {
    let model = IntakeModel(fetchInfo: { _ in throw CancellationError() }, enqueue: { _, _ in })
    #expect(model.folder == nil)
  }

  // MARK: - Fixtures

  private static let videoLink = "https://www.twitch.tv/videos/2844548319"
  private static let videoID = "2844548319"
  private static let clipLink = "https://clips.twitch.tv/TangibleGiantPancakeKappa"
  private static let clipSlug = "TangibleGiantPancakeKappa"

  private static let folder = URL(filePath: "/Users/someone/Movies")

  /// Deliberately just after midnight UTC: read in Pacific it is the evening
  /// of the *previous* day, which is the day the name has to use (§4).
  private static let createdAt = ISO8601DateFormatter().date(from: "2026-08-24T04:30:00Z")!

  /// Every test passes this calendar, so the expected dates below hold
  /// wherever the suite runs.
  private static var pacific: Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
    return calendar
  }

  private static func info(
    streamer: String = "leighxp",
    title: String = "A Stream",
    duration: Duration = .seconds(3600),
    qualities: [StreamQuality] = [
      StreamQuality(name: "1080p60", resolution: "1920x1080", bitsPerSecond: 8_000_000),
      StreamQuality(name: "720p60", resolution: "1280x720", bitsPerSecond: 3_000_000),
    ])
    -> VideoInfo
  {
    VideoInfo(
      streamer: streamer,
      title: title,
      createdAt: createdAt,
      duration: duration,
      qualities: qualities)
  }

  /// Captures what `add()` hands to the queue.
  private final class Recorder {
    var templates: [(template: JobTemplate, title: String)] = []
  }

  private func makeModel(
    info: VideoInfo? = IntakeModelTests.info(),
    failure: Error? = nil,
    recorder: Recorder = Recorder())
    -> IntakeModel
  {
    IntakeModel(
      fetchInfo: { _ in
        if let failure { throw failure }
        guard let info else { throw VideoInfoFetchError.unparseableOutput(snippet: "") }
        return info
      },
      enqueue: { recorder.templates.append((template: $0, title: $1)) },
      calendar: Self.pacific)
  }

  /// A model with metadata settled, a folder chosen, and `.video` as its
  /// output — the minimum state in which Add is legal.
  private func loadedModel(
    link: String = IntakeModelTests.videoLink,
    info: VideoInfo = IntakeModelTests.info(),
    recorder: Recorder = Recorder())
    async -> IntakeModel
  {
    let model = makeModel(info: info, recorder: recorder)
    model.linkText = link
    await model.load()
    model.folder = Self.folder
    return model
  }

  /// A VOD with settled metadata offering exactly one quality, so a
  /// composite's geometry is easy to predict. `quality` also becomes the
  /// model's own selection when it is non-empty; left empty, the model keeps
  /// its default of "best available" and the fixture still needs a rendition
  /// on offer for `compositeQuality`'s fallback to resolve.
  ///
  /// Reuses `loadedModel` rather than inventing a second way to settle
  /// metadata — the only difference is the single, resolution-bearing quality
  /// a composite needs.
  private func loaded(
    quality: String,
    resolution: String,
    bitsPerSecond: Int = 6_000_000)
    async
    -> IntakeModel
  {
    let name = quality.isEmpty ? "source" : quality
    let model = await loadedModel(
      info: Self.info(qualities: [
        StreamQuality(name: name, resolution: resolution, bitsPerSecond: bitsPerSecond),
      ]))
    model.quality = quality
    return model
  }

  /// The clip equivalent of `loaded(quality:resolution:)` — same fixture
  /// mechanism, a clip link instead of a VOD one.
  private func loadedClip(
    quality: String,
    resolution: String,
    bitsPerSecond: Int = 6_000_000)
    async
    -> IntakeModel
  {
    let name = quality.isEmpty ? "source" : quality
    let model = await loadedModel(
      link: Self.clipLink,
      info: Self.info(qualities: [
        StreamQuality(name: name, resolution: resolution, bitsPerSecond: bitsPerSecond),
      ]))
    model.quality = quality
    return model
  }

  private func videoRequest(of template: JobTemplate) -> VideoRequest? {
    guard case .video(let request) = template.media else { return nil }
    return request
  }

  private func clipRequest(of template: JobTemplate) -> ClipRequest? {
    guard case .clip(let request) = template.media else { return nil }
    return request
  }

  // MARK: - Add's preconditions

  /// The positive control for every "Add is disabled" test below. Without it
  /// they would all pass just as well against a `canAdd` that is simply
  /// always false.
  @Test func addIsEnabledWithMetadataAFolderAndOneOutput() async {
    let model = await loadedModel()
    #expect(model.canAdd)
  }

  @Test func addIsDisabledUntilMetadataHasSettled() async {
    let model = makeModel()
    model.linkText = Self.videoLink
    model.folder = Self.folder

    #expect(!model.canAdd, "no metadata has been asked for yet")

    await model.load()
    #expect(model.canAdd)
  }

  @Test func addIsDisabledWithNoFolderChosen() async {
    let model = await loadedModel()
    model.folder = nil

    #expect(!model.canAdd)
  }

  @Test func addIsDisabledWhenTheLinkIsNotATwitchAddress() async {
    let model = await loadedModel()
    model.linkText = "https://example.com/videos/123"

    #expect(model.isLinkUnrecognized)
    #expect(!model.canAdd)
  }

  /// Metadata belongs to the link it was fetched for. Pasting another one
  /// must disable Add until that link's own fetch settles, or a job gets
  /// composed for one video out of another's details.
  @Test func addIsDisabledAgainOnceTheLinkChanges() async {
    let model = await loadedModel()
    #expect(model.canAdd)

    model.linkText = "https://www.twitch.tv/videos/999999"

    #expect(!model.canAdd)
    #expect(model.info == nil, "the previous video's details are not this link's")
  }

  // MARK: - Naming

  @Test func theNameIsPrefilledFromTheVideosOwnMetadata() async {
    let model = await loadedModel()
    #expect(model.name == "leighxp - 2026-08-23 - A Stream")
  }

  /// `createdAt` is 04:30 UTC on the 24th; in Pacific that is the evening of
  /// the 23rd, and the 23rd is the day both the streamer and the viewer think
  /// it happened (design doc §4).
  @Test func theNameUsesTheLocalDateRatherThanTheUTCOne() async {
    let model = await loadedModel()
    #expect(model.name.contains("2026-08-23"))
    #expect(!model.name.contains("2026-08-24"))
  }

  /// The base name reserves room for the only suffix an output can take —
  /// `".mp4"`, 4 bytes — whether the job produces a plain video or a
  /// composite, since both share that same suffix (a composite replaces the
  /// video it stacks rather than accompanying it).
  @Test func aLongTitleLeavesRoomForTheOnlySuffix() async throws {
    let model = await loadedModel(info: Self.info(title: String(repeating: "a", count: 400)))
    #expect(model.name.utf8.count == 255 - 4, "reserved for \".mp4\"")

    let template = try #require(model.composedTemplate())
    let name = try #require(videoRequest(of: template)?.destination?.lastPathComponent)
    #expect(name.utf8.count <= 255, "\(name) is \(name.utf8.count) bytes")
  }

  /// The name field is the user's, and it is the seam the prefilled-name test
  /// above cannot reach: that name arrives from `load()` already reserved, so
  /// re-sanitizing it with any budget at all leaves it unchanged. A name the
  /// user edited or pasted has had no reservation applied, and `outputBaseName`
  /// is the only thing standing between it and a path over the filesystem's
  /// 255-byte limit.
  @Test func aLongEditedNameStillFitsInAFilename() async throws {
    let model = await loadedModel()
    model.name = String(repeating: "b", count: 250)

    let template = try #require(model.composedTemplate())
    let name = try #require(videoRequest(of: template)?.destination?.lastPathComponent)
    #expect(name.utf8.count <= 255, "\(name.utf8.count) bytes: \(name)")
  }

  /// The name field is the user's, and a user can type a `/`. Left alone it
  /// would turn `appending(path:)` into a directory traversal rather than a
  /// filename.
  @Test func anEditedNameIsSanitisedBeforeItBecomesAPath() async throws {
    let model = await loadedModel()
    model.name = "why/not: both"

    let template = try #require(model.composedTemplate())
    let destination = try #require(videoRequest(of: template)?.destination)

    #expect(destination.lastPathComponent == "why-not- both.mp4")
    #expect(destination.deletingLastPathComponent().path == Self.folder.path)
  }

  @Test func anEmptiedNameFallsBackRatherThanDisablingAdd() async throws {
    let model = await loadedModel()
    model.name = "   "

    let template = try #require(model.composedTemplate())
    #expect(videoRequest(of: template)?.destination?.lastPathComponent == "untitled.mp4")
  }

  // MARK: - Output (design doc §3)

  @Test func videoOnlyProducesNoChatAndNoComposite() async throws {
    let model = await loaded(quality: "1080p60", resolution: "1920x1080")
    model.output = .video
    let template = try #require(model.composedTemplate())
    #expect(template.chat == nil)
    #expect(template.render == nil)
    #expect(template.composite == nil)
    #expect(template.media != nil)
  }

  @Test func videoWithChatKeepsOnlyTheCompositeDestination() async throws {
    let model = await loaded(quality: "1080p60", resolution: "1920x1080")
    model.output = .videoWithChat
    let template = try #require(model.composedTemplate())

    let composite = try #require(template.composite)
    #expect(composite.destination.lastPathComponent.hasSuffix(".mp4"))
    #expect(composite.framerate == 60)

    // The inputs are intermediates: one file lands in the user's folder.
    guard case .video(let video)? = template.media else {
      Issue.record("expected video media"); return
    }
    #expect(video.destination == nil)
    #expect(template.render?.destination == nil)
    #expect(template.chat?.destination == nil)
    // Built here rather than left to `JobTemplate`'s implied chat request —
    // seeding it from an empty id would produce a job that runs and
    // downloads nothing.
    #expect(template.chat?.videoID == Self.videoID)
  }

  /// The composite's `bitrateMbps` and `duration` are its own fields, not
  /// `framerate`'s neighbours by coincidence — both have to be seeded from
  /// the chosen quality and the video's own duration, not left at some
  /// default that happens to compile.
  @Test func theCompositeSeedsItsBitrateAndDurationFromTheChosenQuality() async throws {
    let model = await loaded(quality: "1080p60", resolution: "1920x1080", bitsPerSecond: 10_000_000)
    model.output = .videoWithChat
    let composite = try #require(model.composedTemplate()?.composite)
    #expect(composite.bitrateMbps == 10)
    #expect(composite.duration == .seconds(3600), "the hour-long duration `Self.info()` fixes")
  }

  @Test func aClipGetsTheSameTwoChoicesAsAVOD() async throws {
    let model = await loadedClip(quality: "1080p60", resolution: "1920x1080")
    model.output = .videoWithChat
    let template = try #require(model.composedTemplate())

    guard case .clip(let clip)? = template.media else {
      Issue.record("expected clip media"); return
    }
    #expect(clip.destination == nil)
    #expect(template.composite?.destination != nil)
    // chatdownload --id takes a slug as readily as a VOD id.
    #expect(template.chat?.videoID == clip.clipSlug)
  }

  /// "Best available" leaves the resolution unknown, which is fatal when the
  /// chat's height must equal the video's.
  @Test func compositingResolvesAnEmptyQualityToAConcreteOne() async throws {
    let model = await loaded(quality: "", resolution: "1920x1080")
    model.output = .videoWithChat
    let template = try #require(model.composedTemplate())
    guard case .video(let video)? = template.media else {
      Issue.record("expected video media"); return
    }
    #expect(!video.quality.isEmpty)
  }

  /// Video-only must not have its default changed as a side effect.
  @Test func videoOnlyLeavesAnEmptyQualityAlone() async throws {
    let model = await loaded(quality: "", resolution: "1920x1080")
    model.output = .video
    let template = try #require(model.composedTemplate())
    guard case .video(let video)? = template.media else {
      Issue.record("expected video media"); return
    }
    #expect(video.quality.isEmpty)
  }

  @Test func theRenderMatchesTheVideosGeometry() async throws {
    let model = await loaded(quality: "1080p60", resolution: "1920x1080")
    model.output = .videoWithChat
    let render = try #require(model.composedTemplate()?.render)
    #expect(render.height == 1080)
    #expect(render.width == 360)
    #expect(render.framerate == 30)
    // A transient input that is immediately re-encoded: 3 Mbps would put two
    // generations of lossy H.264 over text on flat backgrounds.
    #expect(render.bitrateMbps >= 12)
  }

  @Test func chatSizeDefaultsToMedium() {
    let model = makeModel()
    #expect(model.chatSize == .medium)
  }

  /// One row per `ChatSize` case, matching the table in
  /// `docs/design/compositing.md` §4 for a 1080p (360-wide) chat column.
  @Test(arguments: [
    (ChatSize.small, 13.0),
    (ChatSize.medium, 16.0),
    (ChatSize.large, 20.0),
  ])
  func chatSizeSetsTheRendersFontSize(size: ChatSize, expectedFontSize: Double) async throws {
    let model = await loaded(quality: "1080p60", resolution: "1920x1080")
    model.output = .videoWithChat
    model.chatSize = size
    let render = try #require(model.composedTemplate()?.render)
    #expect(render.fontSize == expectedFontSize)
  }

  /// `.video` has no render at all, so a chosen chat size — meaningless
  /// without one — must not change what gets composed. `JobTemplate` is not
  /// itself `Equatable` (its `Media` enum carries no such conformance), so
  /// this compares the one part that could plausibly have drifted.
  @Test func chatSizeIsIgnoredWhenNoChatIsRequested() async throws {
    let model = await loaded(quality: "1080p60", resolution: "1920x1080")
    model.output = .video

    model.chatSize = .large
    let large = try #require(model.composedTemplate())
    model.chatSize = .small
    let small = try #require(model.composedTemplate())

    #expect(videoRequest(of: large) == videoRequest(of: small))
    #expect(large.render == nil)
    #expect(large.chat == nil)
    #expect(large.composite == nil)
  }

  /// A clip's rendition list can carry a quality with no pixel dimensions —
  /// `VideoInfo.clipResolution` has no filter for it, unlike a VOD's
  /// `parseQualities`, which skips a variant with no `RESOLUTION` attribute
  /// outright. When *none* of the clip's renditions parse, "best available"
  /// has nothing to fall back to.
  @Test func compositingRefusesWhenNoRenditionCanBeComposited() async throws {
    let qualities = [StreamQuality(name: "720p0-1", resolution: "", bitsPerSecond: 0)]
    let model = await loadedModel(link: Self.clipLink, info: Self.info(qualities: qualities))
    model.output = .videoWithChat

    #expect(model.composedTemplate() == nil)
    #expect(!model.canAdd)
  }

  /// A failed fetch still settles (`hasSettledMetadata` counts `.failed`),
  /// but `info` — and so `qualities` and the composite's duration — stays
  /// nil. A composite needs both, so it refuses rather than crash on a force
  /// unwrap or compose a job with a guessed duration.
  @Test func compositingRefusesWithoutMetadata() async throws {
    let model = makeModel(failure: VideoInfoFetchError.unparseableOutput(snippet: "x"))
    model.linkText = Self.videoLink
    await model.load()
    model.folder = Self.folder
    model.output = .videoWithChat

    #expect(model.info == nil)
    #expect(model.composedTemplate() == nil)
    #expect(!model.canAdd)
  }

  // MARK: - Composite problem

  /// The positive control: a chosen quality that parses fine has nothing to
  /// explain.
  @Test func compositeProblemIsNilWhenTheChosenQualityCanBeComposited() async throws {
    let model = await loaded(quality: "1080p60", resolution: "1920x1080")
    model.output = .videoWithChat
    #expect(model.compositeProblem == nil)
  }

  /// `.video` never makes a quality decision for compositing, so it can never
  /// have a composite problem — even sitting on a quality that could not be
  /// composited.
  @Test func compositeProblemIsNilForVideoOnly() async throws {
    let qualities = [StreamQuality(name: "720p0-1", resolution: "", bitsPerSecond: 0)]
    let model = await loadedModel(link: Self.clipLink, info: Self.info(qualities: qualities))
    model.quality = "720p0-1"

    #expect(model.output == .video, "the default")
    #expect(model.compositeProblem == nil)
  }

  /// The bug the review caught: `compositeQuality` honours an explicit pick
  /// even when it cannot be composited (see its doc comment — silently
  /// substituting a different rendition is worse), which used to mean Add
  /// simply greyed out with nothing on screen explaining why.
  @Test func choosingAnExplicitQualityWithNoDimensionsExplainsWhyAddIsDisabled() async throws {
    let qualities = [
      StreamQuality(name: "1080p60", resolution: "1920x1080", bitsPerSecond: 6_000_000),
      StreamQuality(name: "720p0-1", resolution: "", bitsPerSecond: 0),
    ]
    let model = await loadedModel(link: Self.clipLink, info: Self.info(qualities: qualities))
    model.output = .videoWithChat
    model.quality = "720p0-1"

    // Not silently substituted for the 1080p60 that *would* work.
    #expect(model.composedTemplate() == nil)
    #expect(!model.canAdd)

    let problem = try #require(model.compositeProblem)
    #expect(problem.contains("720p0-1"), "names the rendition, not a generic failure")
    #expect(problem.contains("Pick another quality"), "says what to do, not just what's wrong")
  }

  // MARK: - Quality

  @Test func theQualityPickerOffersWhatTheMetadataListed() async {
    let model = await loadedModel()
    #expect(model.qualities.map(\.name) == ["1080p60", "720p60"])
  }

  @Test func theDefaultQualityIsEmptyMeaningBestAvailable() async throws {
    let model = await loadedModel()
    #expect(model.quality == "")
    let template = try #require(model.composedTemplate())
    #expect(videoRequest(of: template)?.quality == "")
  }

  @Test func theChosenQualityReachesTheRequest() async throws {
    let model = await loadedModel()
    model.quality = "720p60"
    let template = try #require(model.composedTemplate())
    #expect(videoRequest(of: template)?.quality == "720p60")
  }

  /// 8 Mbps over an hour: 8_000_000 x 3600 / 8 bytes.
  @Test func theSizeEstimateIsBitrateTimesDuration() async throws {
    let model = await loadedModel()
    let quality = try #require(model.qualities.first)
    #expect(model.estimatedBytes(for: quality) == 3_600_000_000)
  }

  @Test func thereIsNoSizeEstimateWithoutMetadata() {
    let model = makeModel()
    let quality = StreamQuality(name: "x", resolution: "y", bitsPerSecond: 1)
    #expect(model.estimatedBytes(for: quality) == nil)
  }

  /// The pixel size is on the row because the name does not always imply it:
  /// `480p30` is 852x480, not 854 or 640, and a clip's upstream-derived name
  /// degenerates to things like `720p0`.
  @Test func aQualityRowNamesItsResolutionAndItsEstimate() async throws {
    let model = await loadedModel()
    let quality = try #require(model.qualities.first)

    let label = model.label(for: quality)
    #expect(label.hasPrefix("1080p60"))
    #expect(label.contains("1920x1080"))
    #expect(label.contains("about"), "the estimate is labelled as one (§6)")
    #expect(label.contains("GB"), "3.6 GB, formatted for the reader")
  }

  /// Older clips carry `bitrate: 0` for every rendition, so there is no
  /// estimate to show — and then the resolution is the only thing telling one
  /// row from the next. A zero is the absence of an estimate, not an estimate
  /// of nothing, so it is left off rather than printed as "about Zero KB".
  @Test func aQualityRowWithNoBitrateNamesItsResolutionAndNoEstimate() async throws {
    let qualities = [StreamQuality(name: "720p0-1", resolution: "1280x720", bitsPerSecond: 0)]
    let model = await loadedModel(link: Self.clipLink, info: Self.info(qualities: qualities))
    let quality = try #require(model.qualities.first)

    #expect(model.label(for: quality) == "720p0-1 · 1280x720")
  }

  /// A rendition Twitch described with neither pixel dimensions nor a usable
  /// `quality` string: the row is the bare name rather than a dangling
  /// separator.
  @Test func aQualityRowWithNoResolutionIsJustTheName() {
    let model = makeModel()
    let quality = StreamQuality(name: "audio_only", resolution: "", bitsPerSecond: 0)
    #expect(model.label(for: quality) == "audio_only")
  }

  // MARK: - Clips (design doc §8)

  @Test func aClipTargetHidesTrimOptions() async {
    let clip = await loadedModel(link: Self.clipLink)
    #expect(!clip.showsTrimOptions)

    let video = await loadedModel()
    #expect(video.showsTrimOptions, "a VOD still offers them")
  }

  @Test func aClipTargetOffersTheClipsOwnQualities() async throws {
    let qualities = [StreamQuality(name: "1080", resolution: "1920x1080", bitsPerSecond: 6_000_000)]
    let model = await loadedModel(link: Self.clipLink, info: Self.info(qualities: qualities))

    #expect(model.qualities == qualities)
    model.quality = "1080"
    let template = try #require(model.composedTemplate())
    #expect(clipRequest(of: template)?.quality == "1080")
  }

  @Test func aClipComposesAClipDownloadNotAVideoOne() async throws {
    let model = await loadedModel(link: Self.clipLink)
    let template = try #require(model.composedTemplate())

    #expect(clipRequest(of: template)?.clipSlug == Self.clipSlug)
    #expect(videoRequest(of: template) == nil)
  }

  /// Trim text typed while a VOD was in the field must not leak into a clip's
  /// job: clips have no trim, and its chat request would otherwise be
  /// silently narrowed to a window the clip does not have.
  @Test func trimTextIsIgnoredEntirelyForAClip() async throws {
    let model = await loadedModel(link: Self.clipLink)
    model.output = .videoWithChat
    model.trimStartText = "1:00"
    model.trimEndText = "2:00"

    let template = try #require(model.composedTemplate())
    #expect(template.chat?.trimStart == nil)
    #expect(template.chat?.trimEnd == nil)
    #expect(model.canAdd, "a hidden field cannot make Add refuse")
  }

  // MARK: - Trim

  /// A trimmed video rendered against the whole VOD's chat is wrong output
  /// that looks like a success, so both requests get the same window.
  @Test func trimTimesReachBothTheVideoAndItsChat() async throws {
    let model = await loadedModel()
    model.output = .videoWithChat
    model.trimStartText = "1:00"
    model.trimEndText = "1:02:03"

    let template = try #require(model.composedTemplate())
    #expect(videoRequest(of: template)?.trimStart == .seconds(60))
    #expect(videoRequest(of: template)?.trimEnd == .seconds(3723))
    #expect(template.chat?.trimStart == .seconds(60))
    #expect(template.chat?.trimEnd == .seconds(3723))
  }

  @Test func noTrimTextMeansNoTrim() async throws {
    let model = await loadedModel()
    let template = try #require(model.composedTemplate())
    #expect(videoRequest(of: template)?.trimStart == nil)
    #expect(videoRequest(of: template)?.trimEnd == nil)
  }

  @Test func anUnreadableTrimTimeRefusesRatherThanReadingAsNoTrim() async {
    let model = await loadedModel()
    model.trimStartText = "half an hour"

    #expect(model.trimIsInvalid)
    #expect(!model.canAdd)
  }

  @Test func anEndAtOrBeforeTheStartRefuses() async {
    let model = await loadedModel()
    model.trimStartText = "2:00"
    model.trimEndText = "1:00"
    #expect(!model.canAdd)

    model.trimEndText = "2:00"
    #expect(!model.canAdd, "a zero-length trim is not a trim")

    model.trimEndText = "2:01"
    #expect(model.canAdd)
  }

  @Test func timecodesAreReadAsSecondsMinutesAndHours() {
    #expect(Timecode.parse("90") == .seconds(90))
    #expect(Timecode.parse("1:30") == .seconds(90))
    #expect(Timecode.parse("1:02:03") == .seconds(3723))
    #expect(Timecode.parse(" 1:30 ") == .seconds(90))
  }

  /// Swift traps on integer overflow, so an over-long number in the trim
  /// field used to take the whole app down — from a text field, with no
  /// privileged input. Too big to be a time is invalid input like any other.
  @Test func anOverflowingTimecodeIsRejectedRatherThanTrapping() async {
    #expect(Timecode.parse("999999999999999999:0") == nil, "overflows the x60")
    #expect(Timecode.parse("99999999999999999999999999") == nil, "too long for Int at all")
    #expect(Timecode.parse("999999999999999999:59:59") == nil)
    // The largest value that does NOT overflow still has to convert to a
    // `Duration` rather than trapping on the way out.
    #expect(Timecode.parse("9223372036854775807") != nil)

    // And it reaches the sheet as a refusal, not a crash.
    let model = await loadedModel()
    model.trimStartText = "999999999999999999:0"
    #expect(model.trimIsInvalid)
    #expect(!model.canAdd)
  }

  @Test func malformedTimecodesAreRejectedRatherThanCoerced() {
    #expect(Timecode.parse("") == nil)
    #expect(Timecode.parse("abc") == nil)
    #expect(Timecode.parse("1:2:3:4") == nil)
    #expect(Timecode.parse("1:90") == nil, "90 is not a seconds field")
    #expect(Timecode.parse("1:") == nil)
    #expect(Timecode.parse("+5") == nil)
    #expect(Timecode.parse("１:３０") == nil, "full-width digits are not a timecode")
  }

  /// A superseded fetch is not a failure. `.task(id:)` cancels the previous
  /// fetch on every edit to the link, and `generation` cannot hide it — the
  /// replacement has not necessarily incremented the counter by the time the
  /// cancelled one unwinds. Reporting it would flash "Oxbow could not read
  /// that video's details" at someone who is simply still typing.
  @Test func aCancelledFetchIsNotReportedAsAFailure() async {
    let model = makeModel(failure: CancellationError())
    model.linkText = Self.videoLink

    await model.load()

    #expect(model.metadataFailure == nil)
    #expect(!model.hasSettledMetadata, "a cancelled fetch settles nothing")
    #expect(model.isLoadingMetadata, "the replacement fetch is what settles this")
  }

  /// The positive control for the test above: a real failure still shows.
  @Test func aRealFetchFailureIsStillReported() async {
    let model = makeModel(failure: VideoInfoFetchError.unparseableOutput(snippet: "x"))
    model.linkText = Self.videoLink

    await model.load()

    #expect(model.metadataFailure != nil)
    #expect(model.hasSettledMetadata)
  }

  // MARK: - Metadata failure

  @Test func aMetadataFailureIsSurfacedAndTheSheetStaysUsable() async throws {
    let model = makeModel(
      failure: VideoInfoFetchError.helperFailed(
        status: .exited(1),
        standardError: "Unable to get information about VOD\n   at Foo.Bar()"))
    model.linkText = Self.videoLink
    await model.load()
    model.folder = Self.folder

    let failure = try #require(model.metadataFailure)
    #expect(failure.contains("Unable to get information about VOD"), "the helper's own sentence")
    #expect(!failure.contains("at Foo.Bar()"), "but not its stack trace")

    // The fallback: named from the id, and still addable.
    #expect(model.name == Self.videoID)
    #expect(model.canAdd)
    let template = try #require(model.composedTemplate())
    #expect(videoRequest(of: template)?.destination?.lastPathComponent == "2844548319.mp4")
    #expect(model.qualities.isEmpty)
    #expect(model.quality == "", "with no quality list, best available is the only honest choice")
  }

  @Test func aClipsMetadataFailureNamesFromTheSlug() async {
    let model = makeModel(failure: VideoInfoFetchError.unparseableOutput(snippet: "???"))
    model.linkText = Self.clipLink
    await model.load()

    #expect(model.metadataFailure != nil)
    #expect(model.name == Self.clipSlug)
  }

  @Test func aFailureWithNoStandardErrorStillExplainsItself() async throws {
    let model = makeModel(
      failure: VideoInfoFetchError.helperFailed(status: .exited(1), standardError: ""))
    model.linkText = Self.videoLink
    await model.load()

    let failure = try #require(model.metadataFailure)
    #expect(!failure.isEmpty)
  }

  /// A slow fetch for the link the user has already replaced must not land
  /// last and name the job after the wrong video.
  @Test func aSupersededFetchNeverOverwritesTheNewerOne() async {
    let gate = Gate()
    let stale = Self.info(streamer: "stale", title: "Old")
    let fresh = Self.info(streamer: "fresh", title: "New")
    let model = IntakeModel(
      fetchInfo: { id in
        if id == "1111" {
          await gate.wait()
          return stale
        }
        return fresh
      },
      enqueue: { _, _ in },
      calendar: Self.pacific)

    model.linkText = "https://www.twitch.tv/videos/1111"
    let first = Task { await model.load() }
    await waitUntil("the first fetch is in flight") { model.isLoadingMetadata }

    model.linkText = "https://www.twitch.tv/videos/2222"
    await model.load()
    #expect(model.name == "fresh - 2026-08-23 - New")

    await gate.open()
    await first.value

    #expect(model.name == "fresh - 2026-08-23 - New", "the superseded fetch must not write back")
    #expect(model.info?.streamer == "fresh")
  }

  // MARK: - Add

  @Test func addEnqueuesExactlyOneJobTitledAfterItsOutputs() async {
    let recorder = Recorder()
    let model = await loadedModel(recorder: recorder)

    #expect(await model.add())

    #expect(recorder.templates.count == 1)
    #expect(recorder.templates.first?.title == "leighxp - 2026-08-23 - A Stream")
  }

  /// The hazard this path is shaped around: Add must never report success —
  /// which is what dismisses the sheet — without a job to show for it. A
  /// refusal enqueues nothing and says why.
  @Test func addRefusesAndExplainsRatherThanClosingOnNothing() async {
    let recorder = Recorder()
    let model = await loadedModel(recorder: recorder)
    model.folder = nil

    #expect(await model.add() == false)
    #expect(recorder.templates.isEmpty)
    #expect(model.addFailure != nil)
  }

  @Test func aSucceedingAddClearsAnEarlierRefusal() async {
    let recorder = Recorder()
    let model = await loadedModel(recorder: recorder)
    model.folder = nil
    _ = await model.add()
    #expect(model.addFailure != nil)

    model.folder = Self.folder
    #expect(await model.add())
    #expect(model.addFailure == nil)
  }

  // MARK: - Suffixes

  @Test func theReservedSuffixIsTheOnlyOneAnyOutputCanTake() {
    #expect(OutputSuffix.longestBytes == OutputSuffix.video.utf8.count)
    #expect(OutputSuffix.longestBytes == 4)
  }

  // MARK: - Helpers

  /// Lets a test hold a fetch open while it drives the model past it.
  private actor Gate {
    private var isOpen = false
    private var continuation: CheckedContinuation<Void, Never>?

    func wait() async {
      guard !isOpen else { return }
      await withCheckedContinuation { continuation = $0 }
    }

    func open() {
      isOpen = true
      continuation?.resume()
      continuation = nil
    }
  }

  /// Yields until `condition` holds, bounded so a broken implementation fails
  /// the test rather than hanging it.
  private func waitUntil(
    _ description: String,
    yields: Int = 10_000,
    _ condition: () -> Bool)
    async
  {
    for _ in 0..<yields {
      if condition() { return }
      await Task.yield()
    }
    Issue.record("timed out waiting until \(description)")
  }
}
