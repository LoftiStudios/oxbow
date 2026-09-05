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
    fetch: @escaping (String) async -> Result<[ChannelArchive], ChannelFeedError> = { _ in .success([]) })
    -> AddChannelModel
  {
    AddChannelModel(
      store: store ?? WatchStore(fileURL: Self.temporaryFile()),
      preferences: preferences,
      fetch: fetch)
  }
}
