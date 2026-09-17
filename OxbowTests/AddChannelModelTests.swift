import Foundation
import Testing
import OxbowKit
@testable import Oxbow

@MainActor
@Suite("Add Channel model")
struct AddChannelModelTests {

  // MARK: - 1. The login is always normalised, never used raw

  /// Normalize before passing the login into GraphQL.
  @Test func aURLABareLoginAndMixedCaseAllNormaliseBeforeTheFetch() async {
    var received: [String] = []
    let model = makeModel(fetch: { login in
      received.append(login)
      return .success([Self.archive("1")])
    })

    for input in ["https://www.twitch.tv/Ninja", "ninja", "NINJA"] {
      model.loginText = input
      await model.look()
    }

    #expect(received == ["ninja", "ninja", "ninja"])
  }

  /// Invalid logins must never reach fetch.
  @Test func aNonTwitchHostPunctuationAndAnEmptyStringAreRefused() async {
    var fetchCount = 0
    let model = makeModel(fetch: { _ in
      fetchCount += 1
      return .success([])
    })

    model.loginText = "https://example.com/ninja"
    #expect(model.normalisedLogin == nil)
    #expect(model.isLoginUnrecognised)
    await model.look()

    model.loginText = "nin\"ja"
    #expect(model.normalisedLogin == nil)
    #expect(model.isLoginUnrecognised)
    await model.look()

    model.loginText = ""
    #expect(model.normalisedLogin == nil)
    #expect(!model.isLoginUnrecognised, "an empty field is the starting state, not an error")
    await model.look()

    #expect(fetchCount == 0, "an unvalidated login must never reach the fetch")
  }

  // MARK: - 2. Settings freeze at init

  /// Use distinct stored, factory, and edited values to detect a live preference reference.
  @Test func settingsSeedFromPreferencesAtInitAndThenFreeze() {
    let store = Self.store {
      $0.destination = URL(filePath: "/Volumes/Archive")
      $0.qualityCap = .p720
      $0.output = .video
      $0.chatSize = .large
    }
    let model = makeModel(preferences: store)

    #expect(model.folder == URL(filePath: "/Volumes/Archive"))
    #expect(model.qualityCap == .p720)
    #expect(model.output == .video)
    #expect(model.chatSize == .large)

    // Simulate Settings writing through a second value over the shared store.
    var mutator = store
    mutator.destination = URL(filePath: "/Volumes/Elsewhere")
    mutator.qualityCap = .p360
    mutator.output = .videoWithChat
    mutator.chatSize = .small

    #expect(model.folder == URL(filePath: "/Volumes/Archive"), "frozen, not a live read")
    #expect(model.qualityCap == .p720)
    #expect(model.output == .video)
    #expect(model.chatSize == .large)
  }

  // MARK: - 3. The estimate reflects the current scope

  @Test func theEstimateReflectsScopeQualityCapAndOutput() async {
    let archives = [
      Self.archive("1", duration: .seconds(3600)),
      Self.archive("2", duration: .seconds(3600)),
    ]
    let model = makeModel(
      preferences: Self.store { $0.output = .video },
      fetch: { _ in .success(archives) })
    model.loginText = "ninja"
    await model.look()

    model.scope = .onlyNew
    #expect(model.estimate?.count == 0, "nothing is taken now")
    #expect(model.estimate?.bytes == 0)

    model.scope = .allAvailable
    #expect(model.estimate?.count == 2, "the whole returned set")

    let atBest = model.estimate?.bytes
    model.qualityCap = .p360
    #expect(model.estimate?.bytes != atBest, "a lower cap must change the number")

    model.qualityCap = .best
    let videoOnly = model.estimate?.bytes
    model.output = .videoWithChat
    #expect(model.estimate?.bytes != videoOnly, "a composite must change the number")
  }

  // MARK: - 4. canAdd

  /// Positive control against a canAdd that always returns false.
  @Test func canAddIsTrueOnceALookupSettledWithAnArchiveAndTheLoginNormalised() async {
    let model = makeModel(fetch: { _ in .success([Self.archive("1")]) })
    model.loginText = "ninja"

    await model.look()

    #expect(model.canAdd)
  }

  @Test func canAddIsFalseBeforeALookupHasHappened() {
    let model = makeModel()
    model.loginText = "ninja"

    #expect(!model.canAdd, "typing a login does not itself perform a lookup")
  }

  @Test func canAddIsFalseWhenTheLookupFoundNoArchives() async {
    let model = makeModel(fetch: { _ in .success([]) })
    model.loginText = "ninja"

    await model.look()

    #expect(!model.canAdd)
  }

  @Test func aFailedLookupDoesNotPermitAdding() async {
    let model = makeModel(fetch: { _ in .failure(.noSuchChannel) })
    model.loginText = "ninja"

    await model.look()

    #expect(!model.canAdd)
  }

  @Test func canAddIsFalseWhenNoFolderIsSet() async {
    let model = makeModel(fetch: { _ in .success([Self.archive("1")]) })
    model.loginText = "ninja"
    await model.look()
    #expect(model.canAdd, "the positive control: addable before the folder is cleared")

    model.folder = nil

    #expect(!model.canAdd)
  }

  // MARK: - 5. add() composes a Watch seeded by scope and persists

  @Test func addSeedsSeenFromScopeAndPreservesExistingWatches() async throws {
    let store = WatchStore(fileURL: Self.temporaryFile())
    defer { try? FileManager.default.removeItem(at: store.fileURL.deletingLastPathComponent()) }
    try store.save([Self.watch(login: "day9tv")])

    let archives = [Self.archive("1"), Self.archive("2")]
    let model = makeModel(store: store, fetch: { _ in .success(archives) })
    model.loginText = "ninja"
    model.scope = .onlyNew

    await model.look()
    let added = await model.add()

    #expect(added)
    let saved = try store.load()
    #expect(saved.count == 2, "the pre-existing watch is preserved")
    #expect(saved.contains { $0.login == "day9tv" })
    let ninja = try #require(saved.first { $0.login == "ninja" })
    #expect(ninja.seen == ["1", "2"], "onlyNew marks everything returned as already seen")
  }

  @Test func addAllAvailableSeedsNothing() async throws {
    let store = WatchStore(fileURL: Self.temporaryFile())
    defer { try? FileManager.default.removeItem(at: store.fileURL.deletingLastPathComponent()) }

    let model = makeModel(store: store, fetch: { _ in .success([Self.archive("1"), Self.archive("2")]) })
    model.loginText = "ninja"
    model.scope = .allAvailable

    await model.look()
    #expect(await model.add())

    let saved = try store.load()
    let ninja = try #require(saved.first { $0.login == "ninja" })
    #expect(ninja.seen.isEmpty, "allAvailable marks nothing, so everything is a finding")
  }

  @Test func addFailsWhenNotYetAddable() async {
    let model = makeModel(fetch: { _ in .success([]) })
    model.loginText = "ninja"
    await model.look()

    #expect(await model.add() == false)
  }

  // MARK: - 6. Adding an already-watched channel replaces rather than duplicates

  /// Duplicate logins would collide in section identity and seen-state updates.
  @Test func addingAnAlreadyWatchedChannelReplacesRatherThanDuplicates() async throws {
    let store = WatchStore(fileURL: Self.temporaryFile())
    defer { try? FileManager.default.removeItem(at: store.fileURL.deletingLastPathComponent()) }
    try store.save([Self.watch(login: "ninja", seen: ["old"])])

    let model = makeModel(store: store, fetch: { _ in .success([Self.archive("new")]) })
    model.loginText = "ninja"
    model.scope = .allAvailable

    await model.look()
    #expect(await model.add())

    let saved = try store.load()
    #expect(saved.count == 1, "replaced, not duplicated")
    #expect(saved[0].seen.isEmpty, "the new watch entirely replaces the old one, seen-set included")
  }

  // MARK: - 7a. add() refuses rather than overwriting on a read failure

  /// A directory at the store path causes a read error. It must not be treated as an empty list
  /// and overwritten by the add.
  @Test func addRefusesRatherThanOverwritingWhenTheWatchListCannotBeRead() async throws {
    let file = Self.temporaryFile()
    defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
    try FileManager.default.createDirectory(at: file, withIntermediateDirectories: true)

    let store = WatchStore(fileURL: file)
    let model = makeModel(store: store, fetch: { _ in .success([Self.archive("1")]) })
    model.loginText = "ninja"
    model.scope = .allAvailable
    await model.look()

    let added = await model.add()

    #expect(!added, "must refuse rather than save over a list it could not read")
    #expect(model.addFailure != nil, "the refusal must say why, not just dismiss")
    // Nothing was ever written: the directory placeholder is exactly what
    // was there before `add()` ran.
    #expect(FileManager.default.fileExists(atPath: file.path))
    var isDirectory: ObjCBool = false
    FileManager.default.fileExists(atPath: file.path, isDirectory: &isDirectory)
    #expect(isDirectory.boolValue, "add() must not have replaced it with a file")
  }

  // MARK: - 7b. look() is guarded against a superseded fetch

  /// An older, slower lookup must not replace the current channel's result.
  @Test func aSupersededLookupNeverOverwritesTheNewerOne() async {
    let gate = Gate()
    let model = makeModel(fetch: { login in
      if login == "stale" {
        await gate.wait()
        return .success([Self.archive("stale-archive")])
      }
      return .success([Self.archive("fresh-archive")])
    })

    model.loginText = "stale"
    let first = Task { await model.look() }
    await waitUntil("the first lookup is in flight") { model.lookup == .loading }

    model.loginText = "fresh"
    await model.look()
    #expect(model.lookup == .loaded([Self.archive("fresh-archive")]))

    await gate.open()
    await first.value

    #expect(
      model.lookup == .loaded([Self.archive("fresh-archive")]),
      "the superseded lookup must not land after the current one")
  }

  // MARK: - 7c. A settled lookup must not survive editing the login away from it

  /// Editing the login without another lookup must invalidate the old result; otherwise the new
  /// watch receives the previous channel's seen IDs.
  @Test func editingTheLoginAfterALookupSettlesInvalidatesItRatherThanComposingFromTheOldOne() async throws {
    let store = WatchStore(fileURL: Self.temporaryFile())
    defer { try? FileManager.default.removeItem(at: store.fileURL.deletingLastPathComponent()) }

    let model = makeModel(store: store, fetch: { login in .success([Self.archive("\(login)-archive")]) })

    model.loginText = "day9tv"
    await model.look()
    #expect(model.canAdd, "the positive control: addable right after its own lookup")

    model.loginText = "ninja"

    #expect(!model.canAdd, "a lookup that describes a different login must not make this one addable")
    #expect(
      model.displayedLookup == .idle,
      "a settled result for a login no longer typed must read as idle, not show day9tv's counts")
    #expect(model.estimate == nil, "must not price day9tv's archives as ninja's backfill")

    let added = await model.add()

    #expect(!added, "must refuse rather than compose a watch for ninja out of day9tv's archives")
    #expect(model.addFailure != nil, "the refusal must say why, not just dismiss")
    let saved = try store.load()
    #expect(saved.isEmpty, "no watch — for either channel — must have been persisted")
  }

  // MARK: - 9. reset() and reseedFromPreferences()

  /// Reset must read stored defaults and clear the reusable window's completed form. Fixture
  /// values distinguish stored, factory, and edited state.
  @Test func resetClearsTheChannelsOwnStateAndReseedsStandingPreferencesFromTheStore() async {
    let preferences = Self.store {
      $0.destination = URL(filePath: "/Volumes/Archive")
      $0.qualityCap = .p480
      $0.output = .video
      $0.chatSize = .large
    }
    let model = makeModel(preferences: preferences, fetch: { _ in .success([Self.archive("1")]) })

    // No lookup has happened yet, so `add()` refuses and leaves a reason
    // behind — the failure `reset()` also has to clear.
    model.loginText = "ninja"
    #expect(await model.add() == false)
    #expect(model.addFailure != nil, "precondition")

    await model.look()
    model.scope = .allAvailable
    model.downloadsAutomatically = true
    model.qualityCap = .p1080
    model.output = .videoWithChat
    model.chatSize = .small
    model.folder = URL(filePath: "/Users/someone/Movies")

    model.reset()

    #expect(model.loginText == "")
    #expect(model.lookup == .idle)
    #expect(model.lookupLogin == nil)
    #expect(model.scope == .onlyNew)
    #expect(model.downloadsAutomatically == false)
    #expect(model.addFailure == nil)
    #expect(model.qualityCap == .p480, "reseeded from the store, not left at the mutated value")
    #expect(model.output == .video)
    #expect(model.chatSize == .large)
    #expect(model.folder == URL(filePath: "/Volumes/Archive"))
  }

  /// Reopening reads Settings changes made while closed, while preserving any in-progress
  /// lookup.
  @Test func reseedFromPreferencesPicksUpAStoreChangedSinceConstructionButLeavesTheChannelAlone() async {
    let preferences = Self.store {
      $0.destination = URL(filePath: "/Users/someone/Movies")
      $0.qualityCap = .best
      $0.output = .videoWithChat
      $0.chatSize = .medium
    }
    let model = makeModel(preferences: preferences, fetch: { _ in .success([Self.archive("1")]) })
    #expect(model.qualityCap == .best, "precondition: seeded at construction")

    // Simulate Settings updating the shared store while the window is closed.
    var mutator = preferences
    mutator.qualityCap = .p480
    mutator.output = .video
    mutator.chatSize = .small
    mutator.destination = URL(filePath: "/Users/someone/Archive")

    // In-progress state must survive reseeding, unlike a full reset.
    model.loginText = "ninja"
    await model.look()
    model.scope = .allAvailable

    model.reseedFromPreferences()

    #expect(model.qualityCap == .p480)
    #expect(model.output == .video)
    #expect(model.chatSize == .small)
    #expect(model.folder == URL(filePath: "/Users/someone/Archive"))
    #expect(model.loginText == "ninja", "reseeding must not clobber an in-progress channel")
    #expect(model.canAdd, "the lookup already in hand must survive a reseed")
    #expect(model.scope == .allAvailable)
  }

  // MARK: - 7. A failed lookup keeps its reason

  /// Lookup failure must remain distinct from a channel with no archives.
  @Test func aFailedLookupKeepsItsReasonRatherThanReadingAsEmpty() async {
    let model = makeModel(fetch: { _ in .failure(.noSuchChannel) })
    model.loginText = "ninja"

    await model.look()

    guard case .failed(let message) = model.lookup else {
      Issue.record("expected a failed lookup, got \(model.lookup)")
      return
    }
    #expect(message == ChannelFeedError.noSuchChannel.localizedDescription)

    if case .loaded(let archives) = model.lookup {
      Issue.record("a failure must never read as .loaded([]): \(archives)")
    }
  }

  // MARK: - 8. add() resolves the real display name, falling back on failure

  /// Persist Twitch's display name, not just the normalized login.
  @Test func addResolvesTheRealDisplayNameBeforePersisting() async throws {
    let store = WatchStore(fileURL: Self.temporaryFile())
    defer { try? FileManager.default.removeItem(at: store.fileURL.deletingLastPathComponent()) }

    let model = makeModel(
      store: store,
      fetch: { _ in .success([Self.archive("1")]) },
      fetchProfile: { _ in .success(ChannelProfile(displayName: "Ninja", avatarURL: nil)) })
    model.loginText = "ninja"
    model.scope = .allAvailable

    await model.look()
    #expect(await model.add())

    let saved = try store.load()
    let ninja = try #require(saved.first { $0.login == "ninja" })
    #expect(ninja.displayName == "Ninja")
  }

  /// A failed display-name lookup falls back to login without blocking the add.
  @Test func aFailedDisplayNameLookupFallsBackToTheNormalisedLoginRatherThanBlockingAdd() async throws {
    let store = WatchStore(fileURL: Self.temporaryFile())
    defer { try? FileManager.default.removeItem(at: store.fileURL.deletingLastPathComponent()) }

    let model = makeModel(
      store: store,
      fetch: { _ in .success([Self.archive("1")]) },
      fetchProfile: { _ in .failure(.noSuchChannel) })
    model.loginText = "ninja"
    model.scope = .allAvailable

    await model.look()
    #expect(await model.add(), "a display-name failure must not block adding the channel")

    let saved = try store.load()
    let ninja = try #require(saved.first { $0.login == "ninja" })
    #expect(ninja.displayName == "ninja")
  }

  // MARK: - 9a. A write landing during the display-name await is not lost

  /// Hold the profile fetch open while a second store writes. Saving the add must load after
  /// the await so that concurrent changes survive.
  @Test func aWriteLandingDuringTheDisplayNameAwaitIsNotClobbered() async throws {
    let store = WatchStore(fileURL: Self.temporaryFile())
    defer { try? FileManager.default.removeItem(at: store.fileURL.deletingLastPathComponent()) }
    try store.save([Self.watch(login: "day9tv", seen: [])])

    let gate = Gate()
    var fetchStarted = false
    let model = makeModel(
      store: store,
      fetch: { _ in .success([Self.archive("1")]) },
      fetchProfile: { _ in
        fetchStarted = true
        await gate.wait()
        return .success(ChannelProfile(displayName: "Ninja", avatarURL: nil))
      })
    model.loginText = "ninja"
    model.scope = .allAvailable
    await model.look()

    let addTask = Task { await model.add() }
    await waitUntil("the display-name fetch has started") { fetchStarted }

    // Simulate another watch-list writer during the suspended fetch.
    var concurrent = try store.load()
    concurrent[0] = concurrent[0].marking(["new-finding"])
    try store.save(concurrent)

    await gate.open()
    let added = await addTask.value

    #expect(added)
    let saved = try store.load()
    #expect(saved.contains { $0.login == "ninja" }, "the new watch must still land")
    let day9tv = try #require(saved.first { $0.login == "day9tv" })
    #expect(
      day9tv.seen.contains("new-finding"),
      "a write that landed during the await must not be clobbered by a stale load")
  }

  // MARK: - 10. Editing seeds from the watch, never from Preferences

  /// Distinct watch and preference values detect accidental reseeding from global defaults.
  @Test func beginEditingSeedsEveryFieldFromTheWatchNotFromPreferences() {
    let preferences = Self.store {
      $0.destination = URL(filePath: "/Volumes/Defaults")
      $0.qualityCap = .best
      $0.output = .videoWithChat
      $0.chatSize = .small
    }
    let watch = Watch(
      login: "leighxp", displayName: "LeighXP",
      settings: .init(
        destinationPath: "/Volumes/Frozen", qualityCap: .p720,
        output: .video, chatSize: .large),
      downloadsAutomatically: true, seen: ["1", "2"])
    let model = makeModel(preferences: preferences)

    model.beginEditing(watch)

    #expect(model.isEditing)
    #expect(model.loginText == "leighxp")
    #expect(model.qualityCap == .p720, "from the watch, not preferences' .best")
    #expect(model.output == .video, "from the watch, not preferences' .videoWithChat")
    #expect(model.chatSize == .large, "from the watch, not preferences' .small")
    #expect(model.folder == URL(filePath: "/Volumes/Frozen"), "from the watch, not preferences' Defaults")
    #expect(model.downloadsAutomatically, "from the watch, not the false default")
  }

  /// Editing neither seeds scope nor performs a backfill lookup, so no estimate applies.
  @Test func editingHasNoEstimateSinceNothingIsBeingTaken() {
    let model = makeModel()
    model.beginEditing(Self.watch(login: "leighxp", seen: ["1"]))

    #expect(model.estimate == nil)
    #expect(!model.hasArchivesToConfigure)
  }

  // MARK: - 11. Saving an edit preserves seen, login and displayName

  /// Editing settings must preserve the watch's seen IDs.
  @Test func savingAnEditPreservesTheSeenSetLoginAndDisplayName() async throws {
    let store = WatchStore(fileURL: Self.temporaryFile())
    defer { try? FileManager.default.removeItem(at: store.fileURL.deletingLastPathComponent()) }
    let original = Self.watch(login: "leighxp", seen: ["ignored-1", "queued-2"])
    try store.save([original])

    let model = makeModel(store: store)
    model.beginEditing(original)
    model.qualityCap = .p480
    model.folder = URL(filePath: "/Users/someone/NewDestination")

    let saved = await model.add()

    #expect(saved)
    let watches = try store.load()
    #expect(watches.count == 1, "an edit replaces, it does not add a second entry")
    let edited = try #require(watches.first { $0.login == "leighxp" })
    #expect(edited.seen == ["ignored-1", "queued-2"], "the ignored finding must not come back")
    #expect(edited.displayName == original.displayName, "unchanged — never re-fetched for an edit")
    #expect(edited.settings.qualityCap == .p480, "the new cap took effect")
    #expect(edited.settings.destinationPath == "/Users/someone/NewDestination")
  }

  /// A sweep may mark new IDs while the edit window is open; saving must retain those newer
  /// marks.
  @Test func savingAnEditPicksUpASeenMarkAddedWhileTheWindowWasOpen() async throws {
    let store = WatchStore(fileURL: Self.temporaryFile())
    defer { try? FileManager.default.removeItem(at: store.fileURL.deletingLastPathComponent()) }
    let original = Self.watch(login: "leighxp", seen: ["1"])
    try store.save([original])

    let model = makeModel(store: store)
    model.beginEditing(original)

    // Simulate a sweep marking archive 2 while editing.
    var current = try store.load()
    current[0] = current[0].marking(["2"])
    try store.save(current)

    model.qualityCap = .p480
    #expect(await model.add())

    let edited = try #require(try store.load().first { $0.login == "leighxp" })
    #expect(
      edited.seen == ["1", "2"],
      "the sweep's mark must survive the edit, not be overwritten by the window's stale snapshot")
  }

  /// A failure may unmark an archive while editing; saving must not restore the stale mark.
  @Test func savingAnEditPreservesAnUnmarkMadeWhileTheWindowWasOpen() async throws {
    let store = WatchStore(fileURL: Self.temporaryFile())
    defer { try? FileManager.default.removeItem(at: store.fileURL.deletingLastPathComponent()) }
    let original = Self.watch(login: "leighxp", seen: ["1", "2"])
    try store.save([original])

    let model = makeModel(store: store)
    model.beginEditing(original)

    // Simulate a failed download returning archive 2 to the inbox.
    var current = try store.load()
    current[0] = current[0].forgetting(["2"])
    try store.save(current)

    model.qualityCap = .p480
    #expect(await model.add())

    let edited = try #require(try store.load().first { $0.login == "leighxp" })
    #expect(
      edited.seen == ["1"],
      "the failure's un-mark must survive the edit, not be reverted by the window's stale snapshot")
  }

  /// Editing one watch must preserve the others.
  @Test func savingAnEditPreservesEveryOtherWatchedChannel() async throws {
    let store = WatchStore(fileURL: Self.temporaryFile())
    defer { try? FileManager.default.removeItem(at: store.fileURL.deletingLastPathComponent()) }
    let target = Self.watch(login: "leighxp", seen: ["1"])
    try store.save([Self.watch(login: "day9tv"), target])

    let model = makeModel(store: store)
    model.beginEditing(target)
    model.output = .videoWithChat

    #expect(await model.add())

    let watches = try store.load()
    #expect(watches.count == 2)
    #expect(watches.contains { $0.login == "day9tv" })
  }

  /// Refuse unreadable state rather than saving over it.
  @Test func savingAnEditRefusesRatherThanOverwritingWhenTheWatchListCannotBeRead() async throws {
    let file = Self.temporaryFile()
    defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
    try FileManager.default.createDirectory(at: file, withIntermediateDirectories: true)

    let store = WatchStore(fileURL: file)
    let model = makeModel(store: store)
    model.beginEditing(Self.watch(login: "leighxp", seen: ["1"]))

    let saved = await model.add()

    #expect(!saved, "must refuse rather than save over a list it could not read")
    #expect(model.addFailure != nil, "the refusal must say why, not just dismiss")
    var isDirectory: ObjCBool = false
    FileManager.default.fileExists(atPath: file.path, isDirectory: &isDirectory)
    #expect(isDirectory.boolValue, "add() must not have replaced it with a file")
  }

  // MARK: - 12. canAdd while editing

  @Test func canAddIsTrueWhileEditingWithNoLookupInvolved() {
    let model = makeModel()
    model.beginEditing(Self.watch(login: "leighxp"))

    #expect(model.canAdd, "editing needs no lookup — only the fields this window lets you change")
  }

  @Test func canAddIsFalseWhileEditingIfTheFolderIsCleared() {
    let model = makeModel()
    model.beginEditing(Self.watch(login: "leighxp"))
    #expect(model.canAdd, "the positive control")

    model.folder = nil

    #expect(!model.canAdd)
  }

  // MARK: - 13. reset() leaves editing mode

  /// Reset must leave the reusable window ready to add, not edit the previous channel.
  @Test func resetClearsEditingModeEntirely() {
    let model = makeModel()
    model.beginEditing(Self.watch(login: "leighxp", seen: ["1"]))
    #expect(model.isEditing, "precondition")

    model.reset()

    #expect(!model.isEditing)
    #expect(model.editingWatch == nil)
  }

  // MARK: - Fixtures

  private static func store(_ configure: (inout Preferences) -> Void = { _ in }) -> Preferences {
    var store = Preferences(
      store: InMemoryPreferenceStore(),
      homeDirectory: URL(filePath: "/Users/t"),
      directoryExists: { _ in true })
    configure(&store)
    return store
  }

  private static func temporaryFile() -> URL {
    URL.temporaryDirectory
      .appending(path: "addchannel-\(UUID().uuidString)")
      .appending(path: "watches.json")
  }

  private static func archive(_ id: String, duration: Duration = .seconds(60)) -> ChannelArchive {
    ChannelArchive(
      id: id, title: "t", duration: duration,
      publishedAt: Date(timeIntervalSince1970: 0), status: .recorded, thumbnailURL: nil)
  }

  private static func watch(login: String, seen: Set<String> = []) -> Watch {
    Watch(
      login: login, displayName: login.capitalized,
      settings: .init(
        destinationPath: "/Users/x/Downloads", qualityCap: .p720,
        output: .video, chatSize: .large),
      downloadsAutomatically: false, seen: seen)
  }

  private func makeModel(
    store: WatchStore? = nil,
    preferences: Preferences = AddChannelModelTests.store(),
    fetch: @escaping (String) async -> Result<[ChannelArchive], ChannelFeedError> = { _ in .success([]) },
    fetchProfile: @escaping (String) async -> Result<ChannelProfile, ChannelFeedError> = { login in .success(ChannelProfile(displayName: login, avatarURL: nil)) })
    -> AddChannelModel
  {
    AddChannelModel(
      store: store ?? WatchStore(fileURL: Self.temporaryFile()),
      preferences: preferences,
      fetch: fetch,
      fetchProfile: fetchProfile)
  }

  /// Gate a fetch so tests can change model state while it is suspended.
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
