import Foundation
import Testing
import OxbowKit
@testable import Oxbow

@MainActor
@Suite("Add Channel model")
struct AddChannelModelTests {

  // MARK: - 1. The login is always normalised, never used raw

  /// A URL, a bare login and mixed case must all reach the fetch as the same
  /// normalised string — never `loginText` itself, which is what an attacker
  /// or a fat-fingered paste would put straight into the GraphQL query body
  /// (`ChannelFeed.query(login:limit:)`'s own doc comment).
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

  /// This is the safety boundary itself: a login that fails to normalise must
  /// never reach `fetch` at all, whatever `look()` is asked to do with it.
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

  /// Proves the freeze §3.2 requires: a store mutated *after* init must not
  /// change a model already open. Every field differs from both its factory
  /// default and the fixture's own defaults, so a model that silently kept a
  /// live reference to `preferences` could not pass this by accident.
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

    // Mutates the same backing store through a second `Preferences` value —
    // standing in for Settings changing the defaults while this sheet is
    // open, the same technique `IntakeModelTests` uses to prove its own
    // freeze/reseed rules.
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

  /// The positive control: without it every "disabled" test below would pass
  /// just as well against a `canAdd` that is simply always false.
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

  /// `composeWatch()` guards on `let folder`, same as the login and the
  /// lookup — this pins that third guard down on its own, since a `Watch
  /// .Settings` cannot exist without a destination.
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

  /// `WatchingModel` keys its sections on the login (`Section.id`) and marks
  /// seen with `firstIndex(where:)` — a duplicate login would half-work in
  /// ways that are hard to see, rather than failing loudly.
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

  /// The bug this guards: `try? store.load() ?? []` cannot tell "genuinely
  /// empty" apart from "could not read it", and used to save a one-channel
  /// list straight over whatever a transient read failure hid. `WatchStore
  /// .load()` throws only when the file exists and could not be read as
  /// data — every decode failure it can hit is recovered internally by
  /// `setAside()` and never propagates — so a directory sitting where the
  /// watch file belongs reproduces exactly that throw without touching
  /// `WatchStore` itself.
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

  /// The bug this guards: a slower fetch for an earlier login landing after
  /// a faster one for the current login would populate `lookup` — and so
  /// whatever `add()` composes — with the wrong channel's archives.
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

  /// The bug this guards, distinct from 7b above: no second fetch is ever in
  /// flight here. The user looks up `day9tv`, then edits the field to
  /// `ninja` without pressing Look Up again — `generation` never advances,
  /// because nothing asked `look()` to run. Without `lookupLogin` and
  /// `displayedLookup`, `canAdd` (which only checks that a login normalises
  /// and that *some* lookup loaded) would stay true, and `composeWatch()`
  /// would build a watch for `ninja` seeded from `day9tv`'s archives —
  /// under the default `.onlyNew` scope, that marks `day9tv`'s ids seen on
  /// a `ninja` watch and leaves every one of `ninja`'s real archives
  /// unseen, the exact inverse of what the scope caption promises.
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

  /// Mirrors `IntakeModelTests.resetReseedsFromTheStoreAndUnticksTheBox`:
  /// every value mutated below differs from both what the store holds and
  /// its factory default, so a `reset()` that merely left things in place,
  /// or that reset to a hardcoded default instead of reading the store,
  /// could not pass this by accident.
  ///
  /// The bug this guards: `AddChannelWindow` is a `Window`, not a
  /// `WindowGroup`, so without a `reset()` called on close, reopening after
  /// a successful add shows that same channel's form again — fully composed,
  /// with Add still the default action. One stray ⏎ then replaces that
  /// channel's watch with `seen` recomputed from the stale lookup.
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

  /// The bug: Add Channel is one `Window` for the app's whole run, seeded
  /// once at construction and re-seeded only by `reset()`, which fires once
  /// per *close*. A Settings change made between a close and the next open —
  /// the ordinary sequence, not an edge case — never reaches the model until
  /// `reseedFromPreferences()` reads the store again on open. Also proves the
  /// narrower half of the contract: unlike `reset()`, this must leave a
  /// channel already typed and looked up alone.
  @Test func reseedFromPreferencesPicksUpAStoreChangedSinceConstructionButLeavesTheChannelAlone() async {
    let preferences = Self.store {
      $0.destination = URL(filePath: "/Users/someone/Movies")
      $0.qualityCap = .best
      $0.output = .videoWithChat
      $0.chatSize = .medium
    }
    let model = makeModel(preferences: preferences, fetch: { _ in .success([Self.archive("1")]) })
    #expect(model.qualityCap == .best, "precondition: seeded at construction")

    // Stands in for Settings writing to the same store while this window is
    // closed — a second `Preferences` value over the same backing store, the
    // same technique `IntakeModelTests` uses for the identical reason.
    var mutator = preferences
    mutator.qualityCap = .p480
    mutator.output = .video
    mutator.chatSize = .small
    mutator.destination = URL(filePath: "/Users/someone/Archive")

    // In-progress state a real open can land on — the window does not
    // always start from a close — which `reseedFromPreferences()` must not
    // clobber the way `reset()` deliberately does.
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

  /// The same distinction `WatchPollResult` draws between `.failed` and
  /// `.found([])`: a failure must read as a visible error, never as a
  /// channel with no archives.
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

  /// The bug this guards: `composeWatch()` used to seed `displayName` with
  /// the normalised (lowercased) login and nothing ever corrected it, so
  /// `watches.json` — and the Watching sidebar reading it — would head the
  /// channel "ninja" forever rather than "Ninja". `add()` now resolves the
  /// real name once, right before persisting.
  @Test func addResolvesTheRealDisplayNameBeforePersisting() async throws {
    let store = WatchStore(fileURL: Self.temporaryFile())
    defer { try? FileManager.default.removeItem(at: store.fileURL.deletingLastPathComponent()) }

    let model = makeModel(
      store: store,
      fetch: { _ in .success([Self.archive("1")]) },
      fetchDisplayName: { _ in .success("Ninja") })
    model.loginText = "ninja"
    model.scope = .allAvailable

    await model.look()
    #expect(await model.add())

    let saved = try store.load()
    let ninja = try #require(saved.first { $0.login == "ninja" })
    #expect(ninja.displayName == "Ninja")
  }

  /// The positive control's failure twin: a missing display name is
  /// cosmetic, not a reason to refuse the whole add, so it falls back to the
  /// normalised login rather than blocking `add()`.
  @Test func aFailedDisplayNameLookupFallsBackToTheNormalisedLoginRatherThanBlockingAdd() async throws {
    let store = WatchStore(fileURL: Self.temporaryFile())
    defer { try? FileManager.default.removeItem(at: store.fileURL.deletingLastPathComponent()) }

    let model = makeModel(
      store: store,
      fetch: { _ in .success([Self.archive("1")]) },
      fetchDisplayName: { _ in .failure(.noSuchChannel) })
    model.loginText = "ninja"
    model.scope = .allAvailable

    await model.look()
    #expect(await model.add(), "a display-name failure must not block adding the channel")

    let saved = try store.load()
    let ninja = try #require(saved.first { $0.login == "ninja" })
    #expect(ninja.displayName == "ninja")
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
    fetchDisplayName: @escaping (String) async -> Result<String, ChannelFeedError> = { login in .success(login) })
    -> AddChannelModel
  {
    AddChannelModel(
      store: store ?? WatchStore(fileURL: Self.temporaryFile()),
      preferences: preferences,
      fetch: fetch,
      fetchDisplayName: fetchDisplayName)
  }

  /// Lets a test hold a fetch open while it drives the model past it. The
  /// same helper `IntakeModelTests` uses for its own generation regression
  /// test.
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
