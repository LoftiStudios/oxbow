import Foundation
import Testing
import OxbowKit
@testable import Oxbow

@MainActor
@Suite("Intake model")
struct IntakeModelTests {

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

  /// A model with metadata settled, a folder chosen, and only the video
  /// toggled on — the minimum state in which Add is legal.
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

  private func videoRequest(of template: JobTemplate) -> VideoRequest? {
    guard case .video(let request) = template.media else { return nil }
    return request
  }

  /// The byte length of whichever output suffix `filename` ends with, so a
  /// test can recover the base name every output shares.
  private func suffixBytes(of filename: String) -> Int {
    let suffixes = [
      OutputSuffix.render, OutputSuffix.chat(.json), OutputSuffix.chat(.text),
      OutputSuffix.chat(.html), OutputSuffix.video,
    ]
    return suffixes.first { filename.hasSuffix($0) }?.utf8.count ?? 0
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

  @Test func addIsDisabledWithNoOutputSelected() async {
    let model = await loadedModel()
    model.isDownloadingMedia = false
    model.isDownloadingChat = false
    model.isRenderingChat = false

    #expect(!model.canAdd)
    #expect(model.composedTemplate() == nil)
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

  /// The base name reserves room for the LONGEST suffix any output can take —
  /// `" - chat.json"`, 12 bytes — whatever the toggles currently say, so the
  /// video and its chat sibling can never disagree about their shared base.
  @Test func aLongTitleLeavesRoomForTheLongestSuffix() async throws {
    let model = await loadedModel(info: Self.info(title: String(repeating: "a", count: 400)))
    #expect(model.name.utf8.count == 255 - 12, "reserved for \" - chat.json\"")

    model.isDownloadingChat = true
    model.isRenderingChat = true
    let template = try #require(model.composedTemplate())
    let names = [
      try #require(videoRequest(of: template)?.destination.lastPathComponent),
      try #require(template.chat?.destination?.lastPathComponent),
      try #require(template.render?.destination.lastPathComponent),
    ]
    for name in names {
      #expect(name.utf8.count <= 255, "\(name) is \(name.utf8.count) bytes")
    }
  }

  /// The name field is the user's, and it is the seam the prefilled-name test
  /// above cannot reach: that name arrives from `load()` already reserved, so
  /// re-sanitizing it with any budget at all leaves it unchanged. A name the
  /// user edited or pasted has had no reservation applied, and `outputBaseName`
  /// is the only thing standing between it and a chat sibling that does not
  /// fit while its video does — the §4 disagreement itself.
  @Test func aLongEditedNameStillLeavesRoomForTheLongestSuffix() async throws {
    let model = await loadedModel()
    model.isDownloadingChat = true
    model.isRenderingChat = true
    model.name = String(repeating: "b", count: 250)

    let template = try #require(model.composedTemplate())
    let names = [
      try #require(videoRequest(of: template)?.destination.lastPathComponent),
      try #require(template.chat?.destination?.lastPathComponent),
      try #require(template.render?.destination.lastPathComponent),
    ]
    for name in names {
      #expect(name.utf8.count <= 255, "\(name.utf8.count) bytes: \(name)")
    }
    // One base name, whatever suffix follows it — the point of reserving.
    #expect(Set(names.map { $0.utf8.count - suffixBytes(of: $0) }).count == 1)
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
    #expect(videoRequest(of: template)?.destination.lastPathComponent == "untitled.mp4")
  }

  // MARK: - Destinations

  @Test func everySelectedOutputSharesOneBaseNameAndItsOwnSuffix() async throws {
    let model = await loadedModel()
    model.isDownloadingChat = true
    model.isRenderingChat = true

    let template = try #require(model.composedTemplate())
    let base = "leighxp - 2026-08-23 - A Stream"

    #expect(videoRequest(of: template)?.destination == Self.folder.appending(path: "\(base).mp4"))
    #expect(template.chat?.destination == Self.folder.appending(path: "\(base) - chat.json"))
    #expect(template.render?.destination == Self.folder.appending(path: "\(base) - chat.mp4"))
  }

  @Test func theChatSuffixFollowsTheChosenFormat() async throws {
    let model = await loadedModel()
    model.isDownloadingChat = true
    model.chatFormat = .html

    let template = try #require(model.composedTemplate())
    #expect(
      template.chat?.destination?.lastPathComponent
        == "leighxp - 2026-08-23 - A Stream - chat.html")
    #expect(template.chat?.format == .html)
  }

  /// A render pairing forces the chat download to JSON
  /// (`JobTemplate.renderInput`), so the delivered file cannot be named
  /// `.html`: that name would promise something the queue does not write.
  @Test func aRenderPairingNamesTheChatFileJSONWhateverTheFormatPickerSays() async throws {
    let model = await loadedModel()
    model.isDownloadingChat = true
    model.chatFormat = .html
    model.isRenderingChat = true

    let template = try #require(model.composedTemplate())
    #expect(template.chat?.destination?.pathExtension == "json")
    #expect(template.chat?.format == .json)
  }

  // MARK: - The chat/render pairing (task-queue.md §10)

  /// Render on, Chat off: the chat file is the render's input and nothing
  /// more, so it gets no destination and is discarded with the workspace.
  @Test func renderWithChatOffGivesTheChatRequestNoDestination() async throws {
    let model = await loadedModel()
    model.isRenderingChat = true
    model.isDownloadingChat = false

    let template = try #require(model.composedTemplate())
    let chat = try #require(template.chat, "a render still needs its chat download")

    #expect(chat.destination == nil)
    // Not merely present: `JobTemplate`'s implied chat request seeds its id
    // from the media, so leaving this to the template would produce an empty
    // id the moment the media toggle is off — a job that runs and downloads
    // nothing.
    #expect(chat.videoID == Self.videoID)
    #expect(template.render != nil)
  }

  @Test func renderWithChatOnDeliversTheChatFileToo() async throws {
    let model = await loadedModel()
    model.isRenderingChat = true
    model.isDownloadingChat = true

    let template = try #require(model.composedTemplate())
    #expect(template.chat?.destination != nil)
  }

  /// The combination that survives with the media toggle off: no video, no
  /// delivered chat, just the rendered chat video.
  @Test func renderAloneStillCarriesTheVideoIDIntoItsChatDownload() async throws {
    let model = await loadedModel()
    model.isDownloadingMedia = false
    model.isDownloadingChat = false
    model.isRenderingChat = true

    let template = try #require(model.composedTemplate())
    #expect(template.media == nil)
    #expect(template.chat?.videoID == Self.videoID)
    #expect(template.chat?.destination == nil)
    #expect(template.render != nil)
  }

  @Test func chatOnItsOwnAsksForNoRender() async throws {
    let model = await loadedModel()
    model.isDownloadingMedia = false
    model.isDownloadingChat = true

    let template = try #require(model.composedTemplate())
    #expect(template.render == nil)
    #expect(template.media == nil)
    #expect(template.chat?.destination != nil)
  }

  /// Task 9 binds its form to `renderOptions`; composition has to carry those
  /// edits into the job rather than build a fresh default request.
  @Test func theRenderFormsOwnSettingsSurviveComposition() async throws {
    let model = await loadedModel()
    model.isRenderingChat = true
    model.renderOptions.width = 700
    model.renderOptions.isSTVEnabled = false

    let render = try #require(model.composedTemplate()?.render)
    #expect(render.width == 700)
    #expect(!render.isSTVEnabled)
    #expect(
      render.destination.lastPathComponent.hasSuffix(" - chat.mp4"),
      "the destination is the model's to set, not the form's")
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

  /// A clip's chat goes through the same toggle — upstream's `chatdownload
  /// --id` takes a VOD or a clip — and must carry the slug, not an empty id.
  @Test func aClipsChatDownloadCarriesTheSlug() async throws {
    let model = await loadedModel(link: Self.clipLink)
    model.isDownloadingChat = true

    let template = try #require(model.composedTemplate())
    #expect(template.chat?.videoID == Self.clipSlug)
  }

  /// Trim text typed while a VOD was in the field must not leak into a clip's
  /// job: clips have no trim, and its chat request would otherwise be
  /// silently narrowed to a window the clip does not have.
  @Test func trimTextIsIgnoredEntirelyForAClip() async throws {
    let model = await loadedModel(link: Self.clipLink)
    model.isDownloadingChat = true
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
    model.isDownloadingChat = true
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
    #expect(videoRequest(of: template)?.destination.lastPathComponent == "2844548319.mp4")
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

  @Test func theReservedSuffixIsTheLongestOneAnyOutputCanTake() {
    let all = [
      OutputSuffix.video,
      OutputSuffix.render,
      OutputSuffix.chat(.json),
      OutputSuffix.chat(.text),
      OutputSuffix.chat(.html),
    ]
    #expect(OutputSuffix.longestBytes == all.map(\.utf8.count).max())
    #expect(OutputSuffix.longestBytes == 12)
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
