import Foundation
import Testing
import OxbowKit
@testable import Oxbow

@MainActor
@Suite("Intake model")
struct IntakeModelTests {

  // MARK: - Seeding

  @Test func composingRefusesOnceTheFolderIsCleared() async {
    let model = await loadedModel()
    model.folder = nil
    #expect(model.composedTemplate() == nil)
  }

  @Test func seedsEveryFieldFromTheStore() {
    let model = makeModel(preferences: Self.store {
      $0.destination = URL(filePath: "/Volumes/Archive")
      $0.qualityCap = .p720
      $0.output = .video
      $0.chatSize = .large
      $0.optionsPanelIsExpanded = false
    })

    #expect(model.folder == URL(filePath: "/Volumes/Archive"))
    #expect(model.qualityCap == .p720)
    #expect(model.output == .video)
    #expect(model.chatSize == .large)
    #expect(model.isOptionsExpanded == false)
  }

  /// Unticked saving must preserve preferences, including on first run.
  @Test func theCheckboxIsUntickedOnAFreshStoreAndOnAConfiguredOne() {
    #expect(makeModel(preferences: Self.store()).wantsToSaveDefaults == false)
    #expect(makeModel(preferences: Self.store { $0.qualityCap = .p480 })
      .wantsToSaveDefaults == false)
  }

  /// Use distinct stored, factory, and edited values. The stored destination exists and differs
  /// from Downloads, so only a fresh preference read can produce the expected result.
  @Test func resetReseedsFromTheStoreAndUnticksTheBox() {
    var store = Preferences(
      store: InMemoryPreferenceStore(), homeDirectory: URL(filePath: "/Users/t"),
      directoryExists: { _ in true })
    store.destination = URL(filePath: "/Volumes/Archive")
    store.qualityCap = .p480
    store.output = .video
    store.chatSize = .large
    store.optionsPanelIsExpanded = false

    let model = makeModel(preferences: store)
    model.output = .videoWithChat
    model.chatSize = .small
    model.qualityCap = .p1080
    model.folder = URL(filePath: "/Users/someone/Movies")
    model.wantsToSaveDefaults = true
    // Do not edit expansion here: it writes through to the store. Its separate reset test
    // changes the store through another Preferences value.

    model.reset()

    #expect(model.output == .video)
    #expect(model.chatSize == .large)
    #expect(model.qualityCap == .p480)
    #expect(
      model.folder == URL(filePath: "/Volumes/Archive"),
      "a reset() that hardcoded ~/Downloads would also pass a missing-destination test")
    #expect(model.destinationFellBack == false)
    #expect(model.isOptionsExpanded == false)
    #expect(model.wantsToSaveDefaults == false)
  }

  /// Change destination from present to missing after construction so reset must recompute the
  /// fallback flag rather than preserve its initial value.
  @Test func resetRereadsDestinationFellBackFromTheStoreRatherThanKeepingInitsAnswer() {
    var store = Preferences(
      store: InMemoryPreferenceStore(), homeDirectory: URL(filePath: "/Users/t"),
      directoryExists: { $0.path != "/Volumes/NowGone" })
    store.destination = URL(filePath: "/Volumes/StillHere")

    let model = makeModel(preferences: store)
    #expect(model.destinationFellBack == false, "precondition: the destination resolves at construction")

    var mutator = store
    mutator.destination = URL(filePath: "/Volumes/NowGone")

    model.reset()

    #expect(model.destinationFellBack, "reset() must re-read the store, not keep init's answer")
  }

  @Test func aMissingStoredDestinationSeedsTheFallbackAndFlagsIt() {
    var store = Preferences(
      store: InMemoryPreferenceStore(), homeDirectory: URL(filePath: "/Users/t"),
      directoryExists: { $0.path != "/Volumes/Unplugged" })
    store.destination = URL(filePath: "/Volumes/Unplugged")

    let model = makeModel(preferences: store)

    #expect(model.folder == URL(filePath: "/Users/t/Downloads"))
    #expect(model.destinationFellBack)
  }

  // MARK: - Reseeding on open

  /// Reopening must read Settings changes made after the previous close.
  @Test func reseedFromPreferencesPicksUpAStoreChangedSinceConstruction() {
    var store = Preferences(
      store: InMemoryPreferenceStore(), homeDirectory: URL(filePath: "/Users/t"),
      directoryExists: { _ in true })
    store.qualityCap = .best
    store.output = .videoWithChat
    store.chatSize = .medium
    store.destination = URL(filePath: "/Users/someone/Movies")
    store.optionsPanelIsExpanded = true

    let model = makeModel(preferences: store)
    #expect(model.qualityCap == .best, "precondition: seeded at construction")

    // Simulate Settings updating the shared store while intake is closed.
    var mutator = store
    mutator.qualityCap = .p480
    mutator.output = .video
    mutator.chatSize = .small
    mutator.destination = URL(filePath: "/Users/someone/Archive")
    mutator.optionsPanelIsExpanded = false

    model.reseedFromPreferences()

    #expect(model.qualityCap == .p480)
    #expect(model.output == .video)
    #expect(model.chatSize == .small)
    #expect(model.folder == URL(filePath: "/Users/someone/Archive"))
    #expect(model.isOptionsExpanded == false)
  }

  /// Reseeding on open must preserve in-progress input and metadata, unlike reset.
  @Test func reseedFromPreferencesLeavesTheInProgressVideoAlone() async {
    let model = await loadedModel()
    model.trimStartText = "00:01:00"
    model.trimEndText = "00:02:00"
    model.wantsToSaveDefaults = true
    let linkBefore = model.linkText
    let nameBefore = model.name
    let qualityBefore = model.quality
    #expect(!linkBefore.isEmpty, "precondition")
    #expect(model.hasSettledMetadata, "precondition")

    model.reseedFromPreferences()

    #expect(model.linkText == linkBefore)
    #expect(model.name == nameBefore)
    #expect(model.quality == qualityBefore)
    #expect(model.trimStartText == "00:01:00")
    #expect(model.trimEndText == "00:02:00")
    #expect(model.wantsToSaveDefaults)
    #expect(model.hasSettledMetadata, "metadata is untouched, not idled the way reset() idles it")
  }

  // MARK: - Pending intake

  /// Pending watch settings differ from global defaults. Stub the destination as reachable; the
  /// next test covers fallback.
  @Test func applySetsTheLinkAndAllFourSettings() {
    let model = makeModel(
      preferences: Self.store {
        $0.qualityCap = .best
        $0.output = .videoWithChat
        $0.chatSize = .medium
        $0.destination = URL(filePath: "/Users/someone/Downloads")
      },
      fileExists: { $0 == URL(filePath: "/Users/someone/Archive") })

    let pending = PendingIntake(
      archiveID: "2844548319",
      settings: Watch.Settings(
        destinationPath: "/Users/someone/Archive",
        qualityCap: .p720,
        output: .video,
        chatSize: .large))

    model.apply(pending)

    #expect(model.linkText == "2844548319")
    #expect(model.target != nil, "a bare numeric id parses as a video")
    #expect(model.qualityCap == .p720)
    #expect(model.output == .video)
    #expect(model.chatSize == .large)
    #expect(model.folder == URL(filePath: "/Users/someone/Archive"))
    #expect(model.destinationFellBack == false)
  }

  /// An unplugged watch destination must fall back to the injected home, not recreate its path
  /// on the boot volume. The preference store's different home detects accidental reseeding.
  @Test func applyFallsBackToDownloadsWhenTheWatchDestinationIsUnreachable() {
    let model = makeModel(
      preferences: Self.store {
        $0.destination = URL(filePath: "/Users/someone/Downloads")
      },
      fileExists: { _ in false },
      homeDirectory: URL(filePath: "/Users/t"))

    let pending = PendingIntake(
      archiveID: "2844548319",
      settings: Watch.Settings(
        destinationPath: "/Volumes/Unplugged/Archive",
        qualityCap: .p720,
        output: .video,
        chatSize: .large))

    model.apply(pending)

    #expect(model.folder == URL(filePath: "/Users/t/Downloads"))
    #expect(model.destinationFellBack)
  }

  /// Apply the cap before loading metadata: otherwise `.best` leaves quality empty instead of
  /// selecting p720's rendition.
  @Test func appliedSettingsAreInPlaceBeforeLoadResolvesQuality() async {
    let model = makeModel(
      preferences: Self.store {
        $0.qualityCap = .best
        $0.output = .videoWithChat
      },
      info: Self.info(qualities: [
        StreamQuality(name: "1080p60", resolution: "1920x1080", bitsPerSecond: 8_000_000),
        StreamQuality(name: "720p60", resolution: "1280x720", bitsPerSecond: 3_000_000),
      ]))

    let pending = PendingIntake(
      archiveID: "2844548319",
      settings: Watch.Settings(
        destinationPath: "/Users/someone/Archive",
        qualityCap: .p720,
        output: .video,
        chatSize: .medium))

    model.apply(pending)
    await model.load()

    #expect(
      model.quality == "720p60",
      "load() must resolve against the applied .p720 cap, not the seeded .best one")
    #expect(model.output == .video, "apply()'s output survives a load() that never touches it")
  }

  // MARK: - Quality, both directions

  @Test func metadataResolvesTheCapIntoARendition() async {
    let model = makeModel(preferences: Self.store { $0.qualityCap = .p720 })
    model.linkText = Self.videoLink
    await model.load()

    #expect(model.quality == "720p60")
  }

  /// Resolving above the cap must not raise the standing preference.
  @Test func anUntouchedPickerLeavesTheCapExactlyAsSeeded() async {
    let model = makeModel(
      preferences: Self.store { $0.qualityCap = .p720 },
      info: Self.info(qualities: [
        StreamQuality(name: "1080p60", resolution: "1920x1080", bitsPerSecond: 8_000_000),
      ]))
    model.linkText = Self.videoLink
    await model.load()

    #expect(model.quality == "1080p60")
    #expect(model.qualityCap == .p720)
  }

  @Test func pickingARenditionRederivesTheCap() async {
    let model = await loadedModel()
    model.selectQuality("720p60")

    #expect(model.quality == "720p60")
    #expect(model.qualityCap == .p720)
  }

  /// Spec §3.8. The bucket is shown at the moment it is chosen, and only when
  /// the pick is not already a rung.
  @Test func theFootnoteAppearsOnlyForAnInexactPick() async {
    let model = await loadedModel(info: Self.info(qualities: [
      StreamQuality(name: "900p30", resolution: "1600x900", bitsPerSecond: 5_000_000),
      StreamQuality(name: "720p60", resolution: "1280x720", bitsPerSecond: 3_000_000),
    ]))

    model.selectQuality("900p30")
    #expect(model.savedQualityNote == .p720)

    model.selectQuality("720p60")
    #expect(model.savedQualityNote == nil)
  }

  /// When a cap resolves upward, the untouched picker still saves its seeded cap. The footnote
  /// must describe that saved value.
  @Test func theFootnoteNamesTheCapAnUntouchedPickerWouldActuallySave() async {
    let model = makeModel(
      preferences: Self.store { $0.qualityCap = .p720 },
      info: Self.info(qualities: [
        StreamQuality(name: "1080p60", resolution: "1920x1080", bitsPerSecond: 8_000_000),
      ]))
    model.linkText = Self.videoLink
    await model.load()

    #expect(model.quality == "1080p60", "precondition: nothing here sits at or under 720p")
    #expect(model.savedQualityNote == .p720, "what a save would write, not 1080p60's own bucket")
  }

  // MARK: - Saving

  @Test func aTickedBoxWritesEveryFieldOnSave() async {
    let store = Self.store()
    let model = await loadedModel(preferences: store)
    // Enable chat so its text-size picker is visible and eligible to save.
    model.output = .videoWithChat
    model.selectQuality("720p60")
    model.chatSize = .large
    model.folder = URL(filePath: "/Volumes/Archive")
    model.wantsToSaveDefaults = true

    model.saveDefaultsIfRequested()

    #expect(store.qualityCap == .p720)
    #expect(store.chatSize == .large)
    #expect(store.destination == URL(filePath: "/Volumes/Archive"))
    #expect(store.hasSavedDefaults)
  }

  @Test func anUntickedBoxWritesNothing() async {
    let store = Self.store()
    let model = await loadedModel(preferences: store)
    model.chatSize = .large

    model.saveDefaultsIfRequested()

    #expect(store.hasSavedDefaults == false)
  }

  /// An untouched p720 cap resolving to 1080p must still persist p720.
  @Test func anUntouchedPickerSavesTheSeededCapNotWhatItResolvedTo() async {
    let store = Self.store { $0.qualityCap = .p720 }
    let model = await loadedModel(
      preferences: store,
      info: Self.info(qualities: [
        StreamQuality(name: "1080p60", resolution: "1920x1080", bitsPerSecond: 8_000_000),
      ]))
    #expect(model.quality == "1080p60", "precondition: nothing here sits at or under 720p")
    model.wantsToSaveDefaults = true

    model.saveDefaultsIfRequested()

    #expect(store.qualityCap == .p720)
  }

  /// Unknown dimensions resolving to best must not overwrite an untouched stored cap.
  @Test func anUntouchedPickerWithNoDimensionsLeavesTheSeededCapAlone() async {
    let store = Self.store { $0.qualityCap = .p720 }
    let model = await loadedModel(
      preferences: store,
      info: Self.info(qualities: [
        StreamQuality(name: "720p0-1", resolution: "", bitsPerSecond: 0),
      ]))
    #expect(model.quality == "", "precondition: nothing here has dimensions to resolve against")
    model.wantsToSaveDefaults = true

    model.saveDefaultsIfRequested()

    #expect(store.qualityCap == .p720)
  }

  /// Video-only after metadata failure is a workaround, not a new output default. Chat size is
  /// withheld separately because its control is hidden; destination isolates the
  /// output-withholding rule.
  @Test func outputIsWithheldWhileMetadataFailed() async {
    let store = Self.store { $0.output = .videoWithChat }
    let model = makeModel(
      preferences: store,
      failure: VideoInfoFetchError.helperFailed(status: .exited(1), standardError: "nope"))
    model.linkText = Self.videoLink
    await model.load()
    model.folder = URL(filePath: "/Volumes/Archive")

    #expect(model.chatProblem != nil, "precondition: the fetch failed")
    model.output = .video
    #expect(model.withholdsOutputFromSave)

    model.chatSize = .large
    model.wantsToSaveDefaults = true
    model.saveDefaultsIfRequested()

    #expect(store.output == .videoWithChat, "not overwritten by the workaround")
    #expect(store.chatSize == .medium, "withheld too — its picker is hidden while output is .video")
    #expect(store.destination == URL(filePath: "/Volumes/Archive"), "unrelated field still saves")
  }

  /// Spec §3.7. Nothing to bucket, so the other three still save.
  @Test func aRenditionWithNoDimensionsWithholdsOnlyQuality() async {
    let store = Self.store { $0.qualityCap = .p1080 }
    let model = await loadedModel(
      preferences: store,
      info: Self.info(qualities: [
        StreamQuality(name: "720p0-1", resolution: "", bitsPerSecond: 0),
      ]))
    // Enable chat to keep its text-size save separate from hidden-control withholding.
    model.output = .videoWithChat
    model.selectQuality("720p0-1")
    model.chatSize = .small
    model.wantsToSaveDefaults = true

    model.saveDefaultsIfRequested()

    #expect(store.qualityCap == .p1080)
    #expect(store.chatSize == .small)
  }

  /// An expired clip's video-only workaround must not turn chat off globally. Destination and
  /// cap remain saveable; hidden chat size follows its own rule.
  @Test func outputIsWithheldWhileChatIsUnavailable() async {
    let store = Self.store { $0.output = .videoWithChat }
    let model = await loadedModel(
      preferences: store, info: Self.info(hasDownloadableChat: false))
    model.output = .videoWithChat

    #expect(model.chatProblem != nil)
    model.output = .video
    #expect(model.withholdsOutputFromSave)

    model.selectQuality("720p60")
    model.chatSize = .large
    model.wantsToSaveDefaults = true
    model.saveDefaultsIfRequested()

    #expect(store.output == .videoWithChat, "withheld: not overwritten by the workaround")
    #expect(store.chatSize == .medium, "withheld too — its picker is hidden while output is .video")
    #expect(store.destination == Self.folder)
    #expect(store.qualityCap == .p720)
  }

  /// Do not save chat size while its picker is hidden.
  @Test func chatSizeIsWithheldWhileVideoOnlyIsSelected() async {
    let store = Self.store { $0.chatSize = .small }
    let model = await loadedModel(preferences: store)
    model.output = .video
    #expect(model.withholdsChatSizeFromSave)

    model.chatSize = .large
    model.wantsToSaveDefaults = true
    model.saveDefaultsIfRequested()

    #expect(store.chatSize == .small, "untouched — the picker that would have set this is hidden")
  }

  /// The positive control: with `.videoWithChat` selected, the picker is on
  /// screen and a save must write what it shows.
  @Test func chatSizeSavesNormallyWithVideoAndChatSelected() async {
    let store = Self.store()
    let model = await loadedModel(preferences: store)
    model.output = .videoWithChat
    #expect(!model.withholdsChatSizeFromSave)

    model.chatSize = .large
    model.wantsToSaveDefaults = true
    model.saveDefaultsIfRequested()

    #expect(store.chatSize == .large)
  }

  // MARK: - Options panel

  @Test func isOptionsExpandedWritesThroughToTheStore() async {
    let store = Self.store { $0.optionsPanelIsExpanded = true }
    let model = await loadedModel(preferences: store)

    model.isOptionsExpanded = false

    #expect(store.optionsPanelIsExpanded == false)
  }

  /// Change expansion through a second Preferences value: editing the model writes through and
  /// would leave reset nothing to restore.
  @Test func resetRereadsIsOptionsExpandedFromTheStore() async {
    let store = Self.store { $0.optionsPanelIsExpanded = true }
    let model = await loadedModel(preferences: store)
    #expect(model.isOptionsExpanded, "precondition: seeded expanded")

    var mutator = store
    mutator.optionsPanelIsExpanded = false

    model.reset()

    #expect(model.isOptionsExpanded == false, "reset() must re-read the store, not keep init's answer")
  }

  /// Collapsing options must not mark download defaults as saved.
  @Test func collapsingThePanelDoesNotSetHasSavedDefaults() async {
    let store = Self.store()
    let model = await loadedModel(preferences: store)

    model.isOptionsExpanded = false

    #expect(store.hasSavedDefaults == false)
  }

  /// §2.5's "collapses it once" — the visible payoff for opting in, tied to
  /// the explicit act of adding.
  @Test func savingCollapsesThePanel() async {
    let model = await loadedModel()
    model.isOptionsExpanded = true
    model.wantsToSaveDefaults = true

    model.saveDefaultsIfRequested()

    #expect(model.isOptionsExpanded == false)
  }

  @Test func notSavingLeavesThePanelAlone() async {
    let model = await loadedModel()
    model.isOptionsExpanded = true

    model.saveDefaultsIfRequested()

    #expect(model.isOptionsExpanded)
  }

  /// Only the first save collapses options; later adds must preserve a panel the user reopened.
  @Test func aLaterSaveLeavesThePanelAlone() async {
    let store = Self.store()
    let model = await loadedModel(preferences: store)
    model.wantsToSaveDefaults = true
    model.saveDefaultsIfRequested()
    #expect(model.isOptionsExpanded == false, "precondition: the first save collapsed it")
    #expect(store.hasSavedDefaults, "precondition: defaults are now configured")

    model.isOptionsExpanded = true
    model.wantsToSaveDefaults = true
    model.saveDefaultsIfRequested()

    #expect(model.isOptionsExpanded, "a later save must not re-collapse a reopened panel")
  }

  /// Refusals force options open so the explanation cannot be hidden behind disabled Add.
  @Test func chatProblemForcesThePanelOpen() async {
    let model = await loadedModel(info: Self.info(hasDownloadableChat: false))
    model.output = .videoWithChat
    model.isOptionsExpanded = false

    #expect(model.chatProblem != nil, "precondition")
    #expect(model.isOptionsEffectivelyExpanded)
  }

  @Test func compositeProblemForcesThePanelOpen() async {
    let model = await loadedModel(
      info: Self.info(qualities: [
        StreamQuality(name: "720p0-1", resolution: "", bitsPerSecond: 0),
      ]))
    model.output = .videoWithChat
    model.selectQuality("720p0-1")
    model.isOptionsExpanded = false

    #expect(model.compositeProblem != nil, "precondition")
    #expect(model.isOptionsEffectivelyExpanded)
  }

  /// Forced expansion is transient; read through a fresh Preferences value to detect unintended
  /// writes.
  @Test func theForcedExpansionNeverReachesTheStore() async {
    let store = Self.store { $0.optionsPanelIsExpanded = false }
    let model = await loadedModel(
      preferences: store, info: Self.info(hasDownloadableChat: false))
    model.output = .videoWithChat
    #expect(model.isOptionsExpanded == false, "precondition: never touched, still collapsed")

    #expect(model.isOptionsEffectivelyExpanded, "forced open by chatProblem")
    #expect(store.optionsPanelIsExpanded == false, "but the store never heard about it")
  }

  /// The expansion binding reads effective visibility.
  @Test func theEffectiveBindingReadsTheForcedOpenValue() async {
    let model = await loadedModel(info: Self.info(hasDownloadableChat: false))
    model.output = .videoWithChat
    model.isOptionsExpanded = false

    #expect(model.isOptionsEffectivelyExpandedBinding, "reads the forced-open value")
  }

  /// Seed expansion true so an unguarded false write is observable even while refusal keeps the
  /// panel visibly open.
  @Test func theEffectiveBindingIgnoresWritesWhileForcedOpen() async {
    let model = await loadedModel(info: Self.info(hasDownloadableChat: false))
    model.output = .videoWithChat
    model.isOptionsExpanded = true
    #expect(model.chatProblem != nil, "precondition: the panel is forced open")

    model.isOptionsEffectivelyExpandedBinding = false

    #expect(model.isOptionsExpanded, "the write was ignored, not merely a no-op value")
  }

  /// Without a refusal, the expansion setter must still persist changes.
  @Test func theEffectiveBindingWritesThroughOnceNothingForcesExpansion() async {
    let model = await loadedModel()
    #expect(model.chatProblem == nil, "precondition")
    #expect(model.compositeProblem == nil, "precondition")
    model.isOptionsExpanded = true

    model.isOptionsEffectivelyExpandedBinding = false

    #expect(model.isOptionsExpanded == false)
  }

  /// Collapsed summary must reflect current output choices.
  @Test func optionsSummaryDescribesOutputQualityAndFolder() async {
    let model = await loadedModel()
    model.output = .video
    model.qualityCap = .p720
    model.folder = URL(filePath: "/Users/t/Movies")

    #expect(model.optionsSummary == "Video · Up to 720p · Movies")
  }

  @Test func optionsSummaryNamesTheChatOutputAndAMissingFolder() async {
    let model = await loadedModel()
    model.output = .videoWithChat
    model.qualityCap = .best
    model.folder = nil

    #expect(model.optionsSummary == "Video + chat · Best available · No folder")
  }

  /// Collapsed and expanded labels must agree on clip versus VOD.
  @Test func optionsSummaryNamesAClipRatherThanAVideo() async {
    let model = await loadedModel(link: Self.clipLink)
    model.output = .videoWithChat
    model.qualityCap = .best
    model.folder = URL(filePath: "/Users/t/Movies")

    #expect(model.optionsSummary == "Clip + chat · Best available · Movies")

    model.output = .video
    #expect(model.optionsSummary == "Clip · Best available · Movies")
  }

  @Test func isClipReflectsTheParsedTarget() async {
    let vod = await loadedModel()
    #expect(vod.isClip == false)

    let clip = await loadedModel(link: Self.clipLink)
    #expect(clip.isClip)
  }

  // MARK: - An occupied destination

  /// A collision changes the action's wording without preventing an authorized replacement.
  @Test func reportsTheFileAlreadySittingAtTheDestination() async {
    let model = await loadedModel(fileExists: { _ in true })
    let expected = Self.folder.appending(path: model.outputBaseName + OutputSuffix.video)

    #expect(model.destinationCollision == expected)
  }

  /// Only the name this job would actually write counts. A folder holding
  /// other files must not read as a collision.
  @Test func reportsNoCollisionWhenTheDestinationItselfIsFree() async {
    let model = await loadedModel(
      fileExists: { $0 == Self.folder.appending(path: "something else.mp4") })

    #expect(model.destinationCollision == nil)
  }

  /// A form with no destination chosen has nothing to collide with, and must
  /// not probe a path it has not got.
  @Test func reportsNoCollisionWithoutAFolder() async {
    let model = await loadedModel(fileExists: { _ in true })
    model.folder = nil

    #expect(model.destinationCollision == nil)
  }

  /// Before the video is known the name is a placeholder, so a warning about
  /// it would be about a file this job is never going to write.
  @Test func reportsNoCollisionBeforeTheVideoIsKnown() {
    let model = makeModel(fileExists: { _ in true })
    model.folder = Self.folder

    #expect(model.destinationCollision == nil)
  }

  /// Replacement permission must come from the same condition that displays the warning.
  @Test func authorizesReplacementOnlyWhenTheWarningWasShown() async throws {
    let warned = await loadedModel(fileExists: { _ in true })
    #expect(try #require(warned.composedTemplate()).replacesExistingFile)

    let unwarned = await loadedModel(fileExists: { _ in false })
    #expect(try !#require(unwarned.composedTemplate()).replacesExistingFile)
  }

  // MARK: - Starting over

  /// The reusable window must not retain the previous link after close.
  @Test func resetClearsEverythingAboutTheVideoJustAdded() async {
    let model = await loadedModel()
    model.trimStartText = "00:01:00"
    model.trimEndText = "00:02:00"
    #expect(!model.linkText.isEmpty)
    #expect(!model.name.isEmpty)

    model.reset()

    #expect(model.linkText.isEmpty)
    #expect(model.name.isEmpty)
    #expect(model.quality.isEmpty)
    #expect(model.trimStartText.isEmpty)
    #expect(model.trimEndText.isEmpty)
    #expect(model.info == nil)
    #expect(!model.hasSettledMetadata)
  }

  /// Other tests set output explicitly, so pin the initial chat-enabled default here.
  @Test func chatIsIncludedByDefault() {
    #expect(DownloadOutput.allCases.first == .videoWithChat, "and listed first")
    #expect(makeModel().output == .videoWithChat)
  }

  /// Wait until fetching begins before reset; otherwise the target guard avoids the race.
  /// Assert the name because `info` is nil after clearing the link even with a stale result.
  @Test func aFetchStillInFlightCannotSettleIntoAResetForm() async {
    let gate = AsyncGate()
    let model = IntakeModel(
      fetchInfo: { _ in
        await gate.arriveAndWait()
        return VideoInfoFetcher.Fetched(info: IntakeModelTests.info(), payload: "")
      },
      enqueue: { _, _ in },
      calendar: Self.pacific,
      preferences: Self.store())
    model.linkText = Self.videoLink

    async let loading: Void = model.load()
    await gate.waitForArrival()
    model.reset()
    await gate.open()
    await loading

    #expect(model.name.isEmpty)
    #expect(model.linkText.isEmpty)
    #expect(!model.hasSettledMetadata)
  }

  /// Lets a fetch be held open across a `reset()`, and lets the test wait
  /// until that fetch has genuinely started, without sleeping for either.
  private actor AsyncGate {
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var arrivals: [CheckedContinuation<Void, Never>] = []
    private var hasArrived = false
    private var isOpen = false

    /// Called from inside the fake fetch: announces that it is running, then
    /// blocks until `open()`.
    func arriveAndWait() async {
      hasArrived = true
      for arrival in arrivals { arrival.resume() }
      arrivals.removeAll()
      guard !isOpen else { return }
      await withCheckedContinuation { waiters.append($0) }
    }

    func waitForArrival() async {
      guard !hasArrived else { return }
      await withCheckedContinuation { arrivals.append($0) }
    }

    func open() {
      isOpen = true
      for waiter in waiters { waiter.resume() }
      waiters.removeAll()
    }
  }

  // MARK: - Fixtures

  private static let videoLink = "https://www.twitch.tv/videos/2844548319"
  private static let videoID = "2844548319"
  private static let clipLink = "https://clips.twitch.tv/TangibleGiantPancakeKappa"
  private static let clipSlug = "TangibleGiantPancakeKappa"


  // MARK: - Not enough room

  /// One-hour fixture peaks: 1080p60 with chat ≈7.9 GB, 720p60 with chat ≈4.2 GB, and plain
  /// 1080p60 ≈3.6 GB.
  private static let gigabyte: Int64 = 1_000_000_000

  /// Space warnings are advisory, not submission gates.
  @Test func aSpaceWarningNeverBlocksAdd() async {
    let model = await loadedModel(volumeSpace: Self.volume(free: Self.gigabyte))
    model.output = .videoWithChat

    #expect(model.spaceWarning != nil, "precondition: a gigabyte cannot hold this job")
    #expect(model.canAdd, "the warning must not gate Add")
  }

  @Test func noSpaceWarningWhenThereIsRoom() async {
    let model = await loadedModel(volumeSpace: Self.volume(free: 100 * Self.gigabyte))
    model.output = .videoWithChat

    #expect(model.spaceWarning == nil)
  }

  /// Do not estimate from placeholder duration before metadata arrives.
  @Test func noSpaceWarningBeforeMetadataSettles() {
    let model = makeModel(volumeSpace: Self.volume(free: 1))
    model.folder = Self.folder

    #expect(model.spaceWarning == nil)
  }

  /// No destination, nothing to check, and in particular no volume to probe.
  @Test func noSpaceWarningWithoutAFolder() async {
    let model = await loadedModel(volumeSpace: Self.volume(free: 1))
    model.output = .videoWithChat
    model.folder = nil

    #expect(model.spaceWarning == nil)
  }

  /// Six GB fits the 4.2 GB 720p job but not the 7.9 GB 1080p job, isolating one useful remedy.
  @Test func theRemedyNamesALowerRenditionThatActuallyFits() async throws {
    let model = await loadedModel(volumeSpace: Self.volume(free: 6 * Self.gigabyte))
    model.output = .videoWithChat

    let remedy = try #require(model.spaceWarning?.remedy)
    #expect(remedy.qualityName == "720p60")
    #expect(remedy.needed < 6 * Self.gigabyte, "a remedy that also does not fit is not a remedy")
  }

  /// Only suggest a remedy that fits.
  @Test func noRemedyWhenEvenTheSmallestRenditionWouldNotFit() async {
    let model = await loadedModel(volumeSpace: Self.volume(free: Self.gigabyte))
    model.output = .videoWithChat

    #expect(model.spaceWarning != nil, "precondition")
    #expect(model.spaceWarning?.remedy == nil)
  }

  /// Five GB fits video alone but not its composite; the warning must track output choice.
  @Test func switchingToVideoOnlyRecomputesTheWarning() async {
    let model = await loadedModel(volumeSpace: Self.volume(free: 5 * Self.gigabyte))

    model.output = .videoWithChat
    #expect(model.spaceWarning != nil)

    model.output = .video
    #expect(model.spaceWarning == nil)
  }

  /// Trimmed jobs must be priced for the selected span.
  @Test func trimmingTheRangeShrinksTheEstimate() async {
    let model = await loadedModel(volumeSpace: Self.volume(free: 5 * Self.gigabyte))
    model.output = .videoWithChat
    #expect(model.spaceWarning != nil, "precondition: the whole hour does not fit")

    model.trimStartText = "0:00"
    model.trimEndText = "10:00"

    #expect(model.spaceWarning == nil, "ten minutes of it does")
  }

  /// A failed capacity probe is unknown, not a shortfall.
  @Test func noSpaceWarningWhenTheVolumeCannotBeRead() async {
    let model = await loadedModel(volumeSpace: VolumeSpace(
      availableBytes: { _ in nil },
      volumeRoot: { _ in nil },
      volumeName: { _ in nil }))
    model.output = .videoWithChat

    #expect(model.spaceWarning == nil)
  }


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
    ],
    hasDownloadableChat: Bool = true)
    -> VideoInfo
  {
    VideoInfo(
      streamer: streamer,
      title: title,
      createdAt: createdAt,
      duration: duration,
      qualities: qualities,
      hasDownloadableChat: hasDownloadableChat)
  }

  /// Captures what `add()` hands to the queue.
  private final class Recorder {
    var templates: [(template: JobTemplate, title: String)] = []
  }

  /// Each test gets isolated in-memory preferences with no real-domain writes.
  private static func store(
    _ configure: (inout Preferences) -> Void = { _ in }) -> Preferences
  {
    // Treat fictional destinations as present so preference reads do not fall back based on the
    // test machine.
    var store = Preferences(
      store: InMemoryPreferenceStore(),
      homeDirectory: URL(filePath: "/Users/t"),
      directoryExists: { _ in true })
    configure(&store)
    return store
  }

  private func makeModel(
    preferences: Preferences = store(),
    info: VideoInfo? = IntakeModelTests.info(),
    failure: Error? = nil,
    recorder: Recorder = Recorder(),
    fileExists: @escaping (URL) -> Bool = { _ in false },
    volumeSpace: VolumeSpace = IntakeModelTests.volume(free: 1_000_000_000_000),
    homeDirectory: URL = URL(filePath: "/Users/t"))
    -> IntakeModel
  {
    IntakeModel(
      fetchInfo: { _ in
        if let failure { throw failure }
        guard let info else { throw VideoInfoFetchError.unparseableOutput(snippet: "") }
        return VideoInfoFetcher.Fetched(info: info, payload: "")
      },
      enqueue: { recorder.templates.append((template: $0, title: $1)) },
      calendar: Self.pacific,
      fileExists: fileExists,
      volumeSpace: volumeSpace,
      homeDirectory: homeDirectory,
      preferences: preferences)
  }

  /// Fixed volume capacity, defaulting to ample room for tests unrelated to disk warnings.
  private static func volume(free: Int64) -> VolumeSpace {
    VolumeSpace(
      availableBytes: { _ in free },
      volumeRoot: { _ in URL(filePath: "/") },
      volumeName: { _ in "Macintosh HD" })
  }

  /// Ready-to-add video-only fixture. Set output explicitly so the chat-enabled app default
  /// does not change unrelated tests.
  private func loadedModel(
    link: String = IntakeModelTests.videoLink,
    preferences: Preferences = store(),
    info: VideoInfo = IntakeModelTests.info(),
    recorder: Recorder = Recorder(),
    fileExists: @escaping (URL) -> Bool = { _ in false },
    volumeSpace: VolumeSpace = IntakeModelTests.volume(free: 1_000_000_000_000))
    async -> IntakeModel
  {
    let model = makeModel(
      preferences: preferences, info: info, recorder: recorder, fileExists: fileExists,
      volumeSpace: volumeSpace)
    model.linkText = link
    await model.load()
    model.folder = Self.folder
    model.output = .video
    return model
  }

  /// Composite fixture with one sized rendition. Empty quality exercises best-available
  /// fallback.
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

  /// Positive control against a `canAdd` that always returns false.
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

  /// Metadata from the previous link must not authorize a new link's submission.
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

  /// 04:30 UTC on the 24th is the evening of the 23rd in Pacific time.
  @Test func theNameUsesTheLocalDateRatherThanTheUTCOne() async {
    let model = await loadedModel()
    #expect(model.name.contains("2026-08-23"))
    #expect(!model.name.contains("2026-08-24"))
  }

  /// Both plain and composite output reserve the four-byte `.mp4` suffix.
  @Test func aLongTitleLeavesRoomForTheOnlySuffix() async throws {
    let model = await loadedModel(info: Self.info(title: String(repeating: "a", count: 400)))
    #expect(model.name.utf8.count == 255 - 4, "reserved for \".mp4\"")

    let template = try #require(model.composedTemplate())
    let name = try #require(videoRequest(of: template)?.destination?.lastPathComponent)
    #expect(name.utf8.count <= 255, "\(name) is \(name.utf8.count) bytes")
  }

  /// An edited name lacks the reservation already applied during metadata loading, so test the
  /// final sanitization boundary separately.
  @Test func aLongEditedNameStillFitsInAFilename() async throws {
    let model = await loadedModel()
    model.name = String(repeating: "b", count: 250)

    let template = try #require(model.composedTemplate())
    let name = try #require(videoRequest(of: template)?.destination?.lastPathComponent)
    #expect(name.utf8.count <= 255, "\(name.utf8.count) bytes: \(name)")
  }

  /// Slashes in user-supplied names must not become path components.
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
    // Explicitly seed chat with the media ID.
    #expect(template.chat?.videoID == Self.videoID)
  }

  /// Composite progress duration must come from the video or selected trim.
  @Test func theCompositeSeedsItsDurationFromTheChosenQuality() async throws {
    let model = await loaded(quality: "1080p60", resolution: "1920x1080", bitsPerSecond: 10_000_000)
    model.output = .videoWithChat
    let composite = try #require(model.composedTemplate()?.composite)
    #expect(composite.framerate == 60)
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

  /// Best-available composite selection must still resolve known dimensions.
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

  /// Pins current forwarding through `commandLineValue`. Its suffix stripping conflicts with
  /// `docs/twitch-metadata.md` §5; see the flagged comment on that property.
  @Test func theVideoRequestPassesTheStrippedQualityNotThePickerName() async throws {
    let model = await loaded(quality: "480p30-1", resolution: "852x480")
    model.output = .video
    let template = try #require(model.composedTemplate())
    let video = try #require(videoRequest(of: template))
    #expect(video.quality == "480p30")
  }

  @Test func theClipRequestPassesTheStrippedQualityNotThePickerName() async throws {
    let model = await loadedClip(quality: "480p30-2", resolution: "852x480")
    model.output = .video
    let template = try #require(model.composedTemplate())
    let clip = try #require(clipRequest(of: template))
    #expect(clip.quality == "480p30")
  }

  /// The composite path must forward through the same CLI quality conversion.
  @Test func theCompositesMediaRequestPassesTheStrippedQualityNotThePickerName() async throws {
    let model = await loaded(quality: "1080p60-1", resolution: "1920x1080")
    model.output = .videoWithChat
    let template = try #require(model.composedTemplate())
    let video = try #require(videoRequest(of: template))
    #expect(video.quality == "1080p60")
  }

  /// `-Portrait` is not affected — measured separately — so a portrait pick
  /// must reach the CLI unchanged rather than stripped.
  @Test func aPortraitQualityReachesTheRequestUnchanged() async throws {
    let model = await loaded(quality: "480p30-Portrait", resolution: "480x853")
    model.output = .video
    let template = try #require(model.composedTemplate())
    let video = try #require(videoRequest(of: template))
    #expect(video.quality == "480p30-Portrait")
  }

  @Test func theRenderMatchesTheVideosGeometry() async throws {
    let model = await loaded(quality: "1080p60", resolution: "1920x1080")
    model.output = .videoWithChat
    let render = try #require(model.composedTemplate()?.render)
    #expect(render.height == 1080)
    #expect(render.width == 360)
    #expect(render.framerate == 30)
    // Pin the intermediate bitrate separately from composite quality targeting.
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

  /// Video-only composition must ignore chat-size changes.
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

  /// Unlike VOD playlist parsing, clip qualities may all lack usable dimensions, leaving no
  /// composite fallback.
  @Test func compositingRefusesWhenNoRenditionCanBeComposited() async throws {
    let qualities = [StreamQuality(name: "720p0-1", resolution: "", bitsPerSecond: 0)]
    let model = await loadedModel(link: Self.clipLink, info: Self.info(qualities: qualities))
    model.output = .videoWithChat

    #expect(model.composedTemplate() == nil)
    #expect(!model.canAdd)
  }

  /// A settled metadata failure still lacks dimensions and duration; composite creation must
  /// refuse it.
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

  @Test func compositeProblemIsNilForVideoOnly() async throws {
    let qualities = [StreamQuality(name: "720p0-1", resolution: "", bitsPerSecond: 0)]
    let model = await loadedModel(link: Self.clipLink, info: Self.info(qualities: qualities))
    model.quality = "720p0-1"

    #expect(model.compositeProblem == nil)
  }

  /// An explicit unusable quality needs a visible explanation, not silent substitution or
  /// unexplained disabled Add.
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

  /// Metadata's 480x853 rounds to the measured 480x852 stream, allowing composition.
  @Test func anOddHeightInMetadataComposesAtItsRoundedDownValue() async throws {
    let qualities = [
      StreamQuality(name: "480p30-Portrait", resolution: "480x853", bitsPerSecond: 1_000_000),
    ]
    let model = await loadedModel(link: Self.clipLink, info: Self.info(qualities: qualities))
    model.output = .videoWithChat
    model.quality = "480p30-Portrait"

    #expect(model.compositeProblem == nil)
    let render = try #require(model.composedTemplate()?.render)
    #expect(render.height == 852, "rounded down from the metadata's odd 853")
  }

  // MARK: - Chat problem

  /// Reject unavailable clip chat before enqueueing; otherwise media can download fully as an
  /// intermediate while failed chat blocks delivery.
  @Test func aClipWhoseBroadcastIsGoneCannotBeAddedWithChat() async throws {
    let model = await loadedModel(
      link: Self.clipLink,
      info: Self.info(
        qualities: [StreamQuality(name: "1080p60", resolution: "1920x1080", bitsPerSecond: 6_000_000)],
        hasDownloadableChat: false))
    model.output = .videoWithChat

    #expect(model.composedTemplate() == nil)
    #expect(!model.canAdd)

    let problem = try #require(model.chatProblem)
    #expect(problem.contains("no longer on Twitch"))
    #expect(!problem.contains("Invalid VOD"), "upstream's diagnostic must not reach the sheet")
  }

  /// Expired chat must not prevent video-only clip downloads.
  @Test func aClipWhoseBroadcastIsGoneCanStillBeAddedAsVideoOnly() async throws {
    let model = await loadedModel(
      link: Self.clipLink,
      info: Self.info(hasDownloadableChat: false))

    #expect(model.chatProblem == nil, "video-only has no chat to explain away")
    #expect(model.canAdd)
  }

  /// The positive control: a clip whose broadcast is still up has nothing to
  /// explain.
  @Test func chatProblemIsNilForAClipThatStillHasItsBroadcast() async throws {
    let model = await loadedClip(quality: "1080p60", resolution: "1920x1080")
    model.output = .videoWithChat
    #expect(model.chatProblem == nil)
  }

  /// VOD chat has no parent-broadcast availability check.
  @Test func chatProblemIsNilForAVod() async throws {
    let model = await loaded(quality: "1080p60", resolution: "1920x1080")
    model.output = .videoWithChat
    #expect(model.chatProblem == nil)
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

  /// A ten-minute trim is one sixth of the fixture's one-hour estimate.
  @Test func theSizeEstimateAccountsForATrimmedWindow() async throws {
    let model = await loadedModel()
    model.trimStartText = "0:00"
    model.trimEndText = "10:00"
    let quality = try #require(model.qualities.first)
    #expect(model.estimatedBytes(for: quality) == 600_000_000)
  }

  @Test func thereIsNoSizeEstimateWithoutMetadata() {
    let model = makeModel()
    let quality = StreamQuality(name: "x", resolution: "y", bitsPerSecond: 1)
    #expect(model.estimatedBytes(for: quality) == nil)
  }

  /// Show actual dimensions because rendition names do not uniquely imply them.
  @Test func aQualityRowNamesItsResolutionAndItsEstimate() async throws {
    let model = await loadedModel()
    let quality = try #require(model.qualities.first)

    let label = model.label(for: quality)
    #expect(label.hasPrefix("1080p60"))
    #expect(label.contains("1920x1080"))
    #expect(label.contains("about"), "the estimate is labelled as one (§6)")
    #expect(label.contains("GB"), "3.6 GB, formatted for the reader")
  }

  /// Zero bitrate on old clips means no estimate; keep resolution without displaying a
  /// zero-byte size.
  @Test func aQualityRowWithNoBitrateNamesItsResolutionAndNoEstimate() async throws {
    let qualities = [StreamQuality(name: "720p0-1", resolution: "1280x720", bitsPerSecond: 0)]
    let model = await loadedModel(link: Self.clipLink, info: Self.info(qualities: qualities))
    let quality = try #require(model.qualities.first)

    #expect(model.label(for: quality) == "720p0-1 · 1280x720")
  }

  /// Missing dimensions must leave no dangling separator.
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

  /// VOD trim fields must not leak into clip requests.
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

  /// Media and implied chat must share the trim range.
  @Test func trimTimesReachBothTheVideoAndItsChat() async throws {
    let model = await loadedModel(info: Self.info(duration: .seconds(7200)))
    model.output = .videoWithChat
    model.trimStartText = "1:00"
    model.trimEndText = "1:02:03"

    let template = try #require(model.composedTemplate())
    #expect(videoRequest(of: template)?.trimStart == .seconds(60))
    #expect(videoRequest(of: template)?.trimEnd == .seconds(3723))
    #expect(template.chat?.trimStart == .seconds(60))
    #expect(template.chat?.trimEnd == .seconds(3723))
  }

  /// Composite progress must use trimmed duration, or its fraction and ETA include footage
  /// never encoded.
  @Test func aTrimmedCompositesDurationIsTheTrimmedWindowNotTheWholeVOD() async throws {
    let model = await loaded(quality: "1080p60", resolution: "1920x1080", bitsPerSecond: 10_000_000)
    model.output = .videoWithChat
    model.trimStartText = "10:00"
    model.trimEndText = "40:00"

    let composite = try #require(model.composedTemplate()?.composite)
    #expect(composite.duration == .seconds(1800))
  }

  @Test func aTrimmedCompositesDurationWithOnlyAStartUsesTheVODsEnd() async throws {
    let model = await loaded(quality: "1080p60", resolution: "1920x1080", bitsPerSecond: 10_000_000)
    model.output = .videoWithChat
    model.trimStartText = "10:00"

    let composite = try #require(model.composedTemplate()?.composite)
    // `Self.info()` fixes the VOD at an hour long (see the untrimmed test
    // above), so a 10-minute start with no end runs to 3600s - 600s = 3000s.
    #expect(composite.duration == .seconds(3000))
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

  /// Reject starts beyond video duration before sending them to the helper.
  @Test func refusesATrimPastTheEndOfTheVideo() async {
    let model = await loadedModel(info: Self.info(duration: .seconds(2400)))

    model.trimStartText = "01:00:00"
    #expect(model.trimIsInvalid)

    model.trimStartText = ""
    model.trimEndText = "01:00:00"
    #expect(model.trimIsInvalid)
  }

  /// An end at exactly the last frame is the whole video, which is fine. A
  /// start there selects nothing, which is not.
  @Test func acceptsAnEndAtTheVideosLengthButNotAStartThere() async {
    let model = await loadedModel(info: Self.info(duration: .seconds(2400)))

    model.trimEndText = "00:40:00"
    #expect(!model.trimIsInvalid)

    model.trimEndText = ""
    model.trimStartText = "00:40:00"
    #expect(model.trimIsInvalid)
  }

  @Test func timecodesAreReadAsSecondsMinutesAndHours() {
    #expect(Timecode.parse("90") == .seconds(90))
    #expect(Timecode.parse("1:30") == .seconds(90))
    #expect(Timecode.parse("1:02:03") == .seconds(3723))
    #expect(Timecode.parse(" 1:30 ") == .seconds(90))
  }

  /// Overflowing timecode numbers are invalid input, not a trap.
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

  /// Collapsing trim hides controls without clearing the selection.
  @Test func collapsingTheTrimSectionKeepsTheTimes() {
    let model = IntakeModel(
      fetchInfo: { _ in throw CancellationError() }, enqueue: { _, _ in },
      preferences: Self.store())
    model.linkText = Self.videoLink
    model.isTrimExpanded = true
    model.trimStartText = "00:10:00"
    model.trimEndText = "00:20:00"

    model.isTrimExpanded = false

    #expect(model.trimStartText == "00:10:00")
    #expect(model.trimEndText == "00:20:00")
  }

  /// Hidden trim still applies and remains described by the summary.
  @Test func aCollapsedTrimSectionStillTrims() {
    let model = IntakeModel(
      fetchInfo: { _ in throw CancellationError() }, enqueue: { _, _ in },
      preferences: Self.store())
    model.linkText = Self.videoLink
    model.trimStartText = "00:10:00"
    model.isTrimExpanded = false

    #expect(model.trimStart == .seconds(600))
    #expect(model.trimSummary == "from 00:10:00")
  }

  @Test func summarisesWhicheverEndsAreSet() {
    let model = IntakeModel(
      fetchInfo: { _ in throw CancellationError() }, enqueue: { _, _ in },
      preferences: Self.store())
    model.linkText = Self.videoLink
    #expect(model.trimSummary == nil)

    model.trimStartText = "00:10:00"
    model.trimEndText = "00:20:00"
    #expect(model.trimSummary == "00:10:00 – 00:20:00")

    model.trimStartText = ""
    #expect(model.trimSummary == "up to 00:20:00")

    // Nothing to summarise while the value cannot be read.
    model.trimEndText = "half an hour"
    #expect(model.trimSummary == nil)
  }

  @Test func aClipNeverSummarisesATrim() {
    let model = IntakeModel(
      fetchInfo: { _ in throw CancellationError() }, enqueue: { _, _ in },
      preferences: Self.store())
    model.linkText = Self.clipLink
    model.trimStartText = "00:10:00"
    #expect(model.trimSummary == nil)
  }

  /// Reset also collapses trim for a fresh intake.
  @Test func resettingTheWindowFoldsTheTrimSectionAway() {
    let model = IntakeModel(
      fetchInfo: { _ in throw CancellationError() }, enqueue: { _, _ in },
      preferences: Self.store())
    model.linkText = Self.videoLink
    model.isTrimExpanded = true
    model.trimStartText = "00:10:00"

    model.reset()

    #expect(!model.isTrimExpanded)
    #expect(model.trimStartText.isEmpty)
  }

  /// Changing videos clears trim so the previous video's bounds cannot disable the new
  /// submission.
  @Test func loadingADifferentVideoClearsAnyTrimFromTheLastOne() async {
    let long = Self.info(duration: .seconds(2400))
    let short = Self.info(duration: .seconds(300))
    let model = IntakeModel(
      fetchInfo: { id in
        VideoInfoFetcher.Fetched(info: id == "1111" ? long : short, payload: "")
      },
      enqueue: { _, _ in },
      calendar: Self.pacific,
      preferences: Self.store())

    model.linkText = "https://www.twitch.tv/videos/1111"
    await model.load()
    model.trimStartText = "10:00"
    model.trimEndText = "20:00"

    model.linkText = "https://www.twitch.tv/videos/2222"
    await model.load()

    #expect(!model.isTrimExpanded)
    #expect(model.trimStartText.isEmpty)
    #expect(model.trimEndText.isEmpty)
  }

  /// Cancellation can arrive before a replacement increments generation; it must not flash a
  /// metadata failure while typing.
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

    // The fallback: named from the id, and still addable as video-only.
    #expect(model.name == Self.videoID)
    model.output = .video
    #expect(model.canAdd)
    let template = try #require(model.composedTemplate())
    #expect(videoRequest(of: template)?.destination?.lastPathComponent == "2844548319.mp4")
    #expect(model.qualities.isEmpty)
    #expect(model.quality == "", "with no quality list, best available is the only honest choice")
  }

  /// Metadata failure must explain why composite output is unavailable and offer video-only.
  @Test func aMetadataFailureExplainsWhyChatIsUnavailable() async throws {
    let model = makeModel(
      failure: VideoInfoFetchError.helperFailed(status: .exited(1), standardError: "nope"))
    model.linkText = Self.videoLink
    await model.load()
    model.folder = Self.folder

    #expect(model.output == .videoWithChat, "the default, and the one that cannot be built")
    #expect(!model.canAdd)
    let problem = try #require(model.chatProblem)
    #expect(problem.contains("\"Video\""), "names the output that still works")

    model.output = .video
    #expect(model.chatProblem == nil)
    #expect(model.canAdd)
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
          return VideoInfoFetcher.Fetched(info: stale, payload: "")
        }
        return VideoInfoFetcher.Fetched(info: fresh, payload: "")
      },
      enqueue: { _, _ in },
      calendar: Self.pacific,
      preferences: Self.store())

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

  /// Refused submission must not report success or dismiss the sheet.
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
