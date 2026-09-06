import Foundation
import Testing
import OxbowKit
@testable import Oxbow

@MainActor
@Suite("Watching model")
struct WatchingModelTests {

  private func temporaryStore() -> WatchStore {
    WatchStore(fileURL: URL.temporaryDirectory
      .appending(path: "watching-\(UUID().uuidString)")
      .appending(path: "watches.json"))
  }

  private func watch(
    _ login: String, seen: Set<String> = [],
    settings: Watch.Settings = .init(
      destinationPath: "/Users/x/Downloads", qualityCap: .best,
      output: .videoWithChat, chatSize: .medium),
    downloadsAutomatically: Bool = false
  ) -> Watch {
    Watch(login: login, displayName: login.capitalized,
          settings: settings, downloadsAutomatically: downloadsAutomatically, seen: seen)
  }

  /// A `WatchStore` whose file is actually a directory — `WatchStore.load()`
  /// throws only in this exact shape (a set-aside-worthy decode failure is
  /// recovered internally, so it never propagates), the same trick
  /// `AddChannelModelTests` uses to reach `AddChannelModel.add()`'s own
  /// read-failure branch.
  private func unreadableStore() throws -> WatchStore {
    let file = URL.temporaryDirectory
      .appending(path: "watching-\(UUID().uuidString)")
      .appending(path: "watches.json")
    try FileManager.default.createDirectory(at: file, withIntermediateDirectories: true)
    return WatchStore(fileURL: file)
  }

  private func archive(_ id: String) -> ChannelArchive {
    ChannelArchive(id: id, title: "Stream \(id)", duration: .seconds(3600),
                   publishedAt: Date(timeIntervalSince1970: 0), status: .recorded,
                   thumbnailURL: nil)
  }

  private func model(store: WatchStore) -> WatchingModel {
    WatchingModel(store: store, openIntake: { _, _ in })
  }

  // MARK: - Derivation

  @Test func sectionsMirrorTheSweep() throws {
    let store = temporaryStore()
    try store.save([watch("ninja"), watch("day9tv")])
    let model = model(store: store)
    model.apply([
      .init(login: "ninja", displayName: "Ninja", outcome: .found([archive("1"), archive("2")])),
      .init(login: "day9tv", displayName: "Day9tv", outcome: .found([archive("3")]))])

    #expect(model.sections.map(\.login) == ["ninja", "day9tv"])
    #expect(model.sections[0].archives.map(\.id) == ["1", "2"])
    #expect(model.unreadCount == 3)
  }

  @Test func aFailedChannelKeepsItsReasonAndIsNotCountedAsUnread() throws {
    // Section 7: a failure must read as a failure, never as an empty list.
    let store = temporaryStore()
    try store.save([watch("gone")])
    let model = model(store: store)
    model.apply([.init(login: "gone", displayName: "Gone", outcome: .failed(.noSuchChannel))])

    #expect(model.sections[0].failure != nil)
    #expect(model.sections[0].archives.isEmpty)
    #expect(model.unreadCount == 0)
  }

  @Test func aChannelWithNothingNewIsNotShownAsAFailure() throws {
    let store = temporaryStore()
    try store.save([watch("quiet")])
    let model = model(store: store)
    model.apply([.init(login: "quiet", displayName: "Quiet", outcome: .found([]))])

    #expect(model.sections[0].failure == nil)
    #expect(model.sections[0].archives.isEmpty)
  }

  // MARK: - The dismissal overlay

  @Test func ignoringRemovesTheRowImmediately() throws {
    // `WatchPoller.results` is a snapshot taken against the seen-set as it
    // stood at sweep time, so persisting alone would leave the row on screen
    // until the next sweep — up to an hour of a button appearing to do
    // nothing. The overlay is what makes Ignore feel like it worked.
    let store = temporaryStore()
    try store.save([watch("ninja")])
    let model = model(store: store)
    model.apply([.init(login: "ninja", displayName: "Ninja",
                       outcome: .found([archive("1"), archive("2")]))])

    model.ignore(archive("1"), from: "ninja")

    #expect(model.sections[0].archives.map(\.id) == ["2"])
    #expect(model.unreadCount == 1)
  }

  @Test func ignoringPersistsToTheSeenSet() throws {
    let store = temporaryStore()
    try store.save([watch("ninja")])
    let model = model(store: store)
    model.apply([.init(login: "ninja", displayName: "Ninja", outcome: .found([archive("1")]))])

    model.ignore(archive("1"), from: "ninja")

    #expect(try store.load()[0].seen == ["1"])
  }

  /// The bug: `rebuild()` used to filter a sweep's archives only through the
  /// in-memory `dismissed` overlay, which only ever catches what *this*
  /// model itself wrote through *this* `store`. A seen-set written through a
  /// different `WatchStore` — exactly what `AddChannelModel` does when
  /// Only new re-adds an already-watched channel — left rows on screen the
  /// watch itself already says are seen, for up to an hour until the next
  /// sweep excluded them on its own. No race is needed to reach it: the
  /// watch file already has "1" seen before the very first sweep this test
  /// applies.
  @Test func rebuildAlsoExcludesArchivesTheWatchsOwnSeenSetAlreadyMarks() throws {
    let store = temporaryStore()
    try store.save([watch("ninja", seen: ["1"])])
    let model = model(store: store)

    model.apply([.init(login: "ninja", displayName: "Ninja",
                       outcome: .found([archive("1"), archive("2")]))])

    #expect(
      model.sections[0].archives.map(\.id) == ["2"],
      "id 1 is already in the watch's own seen set, not just the in-memory overlay")
  }

  @Test func ignoringLeavesWatchesCurrentWithoutACallerHavingToRefresh() throws {
    // `markSeen` used to call `rebuild()` — which re-reads `watches` from
    // disk — before persisting the write, so `watches` reflected the file as
    // it stood a moment earlier and stayed stale until something else
    // rebuilt it. Reading `watches` right here, with no `refresh()` in
    // between, is exactly the trap: a caller (`sections` itself, or
    // `QueueView`'s onEdit before it added its own belt-and-braces call)
    // that trusted this value immediately after Ignore got the channel's old,
    // smaller seen-set.
    let store = temporaryStore()
    try store.save([watch("ninja")])
    let model = model(store: store)
    model.apply([.init(login: "ninja", displayName: "Ninja", outcome: .found([archive("1")]))])

    model.ignore(archive("1"), from: "ninja")

    #expect(model.watches.first(where: { $0.login == "ninja" })?.seen == ["1"])
  }

  @Test func addingPersistsAndOpensIntake() throws {
    let store = temporaryStore()
    try store.save([watch("ninja")])
    let opened = OpenedBox()
    let model = WatchingModel(store: store, openIntake: { archive, _ in opened.id = archive.id })
    model.apply([.init(login: "ninja", displayName: "Ninja", outcome: .found([archive("1")]))])

    model.add(archive("1"), from: "ninja")

    #expect(opened.id == "1")
    // Marked seen on Add, not on the eventual download: the watch's job is to
    // stop offering it, and a person who adds it and then cancels at intake
    // has still answered the question the row was asking.
    #expect(try store.load()[0].seen == ["1"])
    #expect(model.sections[0].archives.isEmpty)
  }

  /// The exact shape `OxbowApp` wires in production — its `openIntake`
  /// closure only ever builds a `PendingIntake` from the watch `add` hands it,
  /// never from `Preferences`. `addingPersistsAndOpensIntake` above only pins
  /// the archive id; this pins the other half of the hand-off, that a channel
  /// someone capped at 720p, video-only actually carries those settings to
  /// intake rather than whatever the global defaults happen to be.
  @Test func addHandsIntakeTheWatchsFrozenSettingsNotGlobalPreferences() throws {
    let store = temporaryStore()
    let capped = Watch(
      login: "ninja", displayName: "Ninja",
      settings: .init(
        destinationPath: "/Users/x/Archive", qualityCap: .p720,
        output: .video, chatSize: .large),
      downloadsAutomatically: false, seen: [])
    try store.save([capped])

    var pending: PendingIntake?
    let model = WatchingModel(store: store, openIntake: { archive, watch in
      pending = PendingIntake(archiveID: archive.id, settings: watch.settings)
    })
    model.apply([.init(login: "ninja", displayName: "Ninja", outcome: .found([archive("1")]))])

    model.add(archive("1"), from: "ninja")

    let handedOff = try #require(pending)
    #expect(handedOff.archiveID == "1")
    #expect(handedOff.settings == capped.settings)
  }

  @Test func anActionOnAnUnknownChannelIsIgnoredRatherThanCrashing() throws {
    // The watch file can change under us — a later stage will let someone
    // remove a channel while findings from it are still on screen.
    let store = temporaryStore()
    try store.save([watch("ninja")])
    let model = model(store: store)
    model.apply([.init(login: "removed", displayName: "Removed",
                       outcome: .found([archive("1")]))])

    model.ignore(archive("1"), from: "removed")

    #expect(try store.load().map(\.login) == ["ninja"])
  }

  // MARK: - markSeen refuses loudly on an unreadable store

  /// The bug: `dismissed.insert(id)` already hides the row before `markSeen`
  /// ever touches the store, so an unreadable `watches.json` used to fail
  /// completely silently — the row vanished, `add(_:from:)` opened no
  /// intake window, and nothing on screen said why. The other three writers
  /// of `watches.json` (`AddChannelModel.add()` in both modes, and
  /// `stopWatching`) all refuse loudly on the identical condition; this pins
  /// `markSeen`'s own turn to do the same, for both call shapes.
  @Test func ignoringOnAnUnreadableStoreSurfacesTheFailureRatherThanFailingSilently() throws {
    let store = try unreadableStore()
    defer { try? FileManager.default.removeItem(at: store.fileURL.deletingLastPathComponent()) }
    let model = model(store: store)

    model.ignore(archive("1"), from: "ninja")

    #expect(model.markSeenFailure != nil, "the refusal must say why, not just vanish")
  }

  @Test func addingOnAnUnreadableStoreSurfacesTheFailureAndOpensNoIntakeWindow() throws {
    let store = try unreadableStore()
    defer { try? FileManager.default.removeItem(at: store.fileURL.deletingLastPathComponent()) }
    let opened = OpenedBox()
    let model = WatchingModel(store: store, openIntake: { archive, _ in opened.id = archive.id })

    model.add(archive("1"), from: "ninja")

    #expect(opened.id == nil, "no watch to hand to intake means no window should open")
    #expect(model.markSeenFailure != nil, "the refusal must say why, not just vanish")
  }

  @Test func aSweepThatStraddlesADismissalDoesNotBringTheRowBack() throws {
    // `sweep` reads the seen-set once up front, then makes slow sequential
    // per-channel calls. A sweep that was already in flight when the ignore
    // landed finishes with results computed before that write — still
    // containing the just-dismissed archive. An identical payload reapplied
    // is exactly that case, and the row must stay gone rather than reappear.
    let store = temporaryStore()
    try store.save([watch("ninja")])
    let model = model(store: store)
    model.apply([.init(login: "ninja", displayName: "Ninja", outcome: .found([archive("1")]))])
    model.ignore(archive("1"), from: "ninja")

    model.apply([.init(login: "ninja", displayName: "Ninja", outcome: .found([archive("1")]))])

    #expect(model.sections[0].archives.isEmpty)
  }

  @Test func aDismissalDropsOutOfTheOverlayButTheArchiveStaysHiddenViaTheWatchsOwnSeenSet() throws {
    // A sweep computed after the write no longer carries the dismissed id at
    // all, so it drops out of the `dismissed` overlay safely — that set
    // stays bounded instead of growing forever, rather than accumulating
    // every id ever acted on for the life of the app.
    //
    // **Before finding 3's fix, that alone made a later sweep that happened
    // to reuse the same id show it as brand new** — `dismissed` was the
    // *only* thing hiding it. Now `rebuild()` also reconciles against the
    // watch's own `seen` set (`Watch.findings(in:)`), which `ignore()`
    // already committed this id to when it persisted — so the row must stay
    // hidden regardless of what `dismissed` has since forgotten.
    // `dismissed` is left responsible only for the write-failed case its own
    // doc comment describes.
    let store = temporaryStore()
    try store.save([watch("ninja")])
    let model = model(store: store)
    model.apply([.init(login: "ninja", displayName: "Ninja", outcome: .found([archive("1")]))])
    model.ignore(archive("1"), from: "ninja")

    model.apply([.init(login: "ninja", displayName: "Ninja", outcome: .found([]))])
    model.apply([.init(login: "ninja", displayName: "Ninja", outcome: .found([archive("1")]))])

    #expect(
      model.sections[0].archives.isEmpty,
      "the watch's own seen set still hides it, even once dismissed has forgotten it")
  }

  // MARK: - Every watched channel gets a section

  @Test func aChannelNeverPolledStillGetsASectionWithItsSettings() throws {
    // Today: a channel with nothing in `latest` does not appear at all. The
    // model has to load the watch list itself, not only wait for a sweep,
    // or a channel added a moment ago is invisible until the poller catches
    // up to it — which can be minutes away (`WatchingView.isSweeping`'s own
    // doc comment).
    let store = temporaryStore()
    try store.save([watch("ninja",
      settings: .init(destinationPath: "/Users/x/Downloads", qualityCap: .best,
                      output: .videoWithChat, chatSize: .medium))])
    let model = model(store: store)

    #expect(model.sections.map(\.login) == ["ninja"])
    #expect(model.sections[0].archives.isEmpty)
    #expect(model.sections[0].failure == nil)
    #expect(model.sections[0].settingsSummary
      == "Video + chat · Best available · Medium chat · Downloads")
  }

  @Test func twoChannelsWithDifferentSettingsShowTheirOwnSummaries() throws {
    let store = temporaryStore()
    try store.save([
      watch("ninja", settings: .init(
        destinationPath: "/Users/x/Downloads", qualityCap: .best,
        output: .videoWithChat, chatSize: .medium)),
      watch("day9tv", settings: .init(
        destinationPath: "/Users/x/Archive", qualityCap: .p720,
        output: .video, chatSize: .large)),
    ])
    let model = model(store: store)

    let summaries = Dictionary(uniqueKeysWithValues: model.sections.map { ($0.login, $0.settingsSummary) })
    #expect(summaries["ninja"] == "Video + chat · Best available · Medium chat · Downloads")
    // Chat size is withheld when the output does not include chat, matching
    // `IntakeModel.withholdsChatSizeFromSave` — a chat-less watch has no
    // chat size to show.
    #expect(summaries["day9tv"] == "Video · Up to 720p · Archive")
  }

  @Test func automaticDownloadingIsVisibleOnTheSectionWhenItIsOn() throws {
    let store = temporaryStore()
    try store.save([
      watch("ninja", downloadsAutomatically: true),
      watch("day9tv", downloadsAutomatically: false),
    ])
    let model = model(store: store)

    let automatic = Dictionary(
      uniqueKeysWithValues: model.sections.map { ($0.login, $0.downloadsAutomatically) })
    #expect(automatic["ninja"] == true)
    #expect(automatic["day9tv"] == false)
  }

  // MARK: - Stopping a watch

  @Test func stopWatchingRemovesTheWatchAndPersistsPreservingOthers() throws {
    let store = temporaryStore()
    try store.save([watch("ninja"), watch("day9tv")])
    let model = model(store: store)
    model.apply([
      .init(login: "ninja", displayName: "Ninja", outcome: .found([archive("1")])),
      .init(login: "day9tv", displayName: "Day9tv", outcome: .found([archive("2")]))])

    model.stopWatching("ninja")

    #expect(try store.load().map(\.login) == ["day9tv"])
    // Gone immediately, not just on the next sweep — `ninja`'s own row from
    // the sweep just applied must not linger because `latest` still carries
    // it (see `stopWatching`'s own doc comment).
    #expect(model.sections.map(\.login) == ["day9tv"])
    #expect(model.stopWatchingFailure == nil)
  }

  @Test func aSweepThatStraddlesAStopDoesNotResurrectTheStoppedChannel() throws {
    // `WatchPoller.sweep` is sequential and can run for minutes, so a sweep
    // already in flight when Stop Watching runs can still land afterwards —
    // via `apply(_:)`, which replaces `latest` wholesale — still carrying
    // the stopped channel's own entry. Reapplying the identical sweep here
    // stands in for exactly that stale landing, and the row must stay gone
    // rather than come back until the next real sweep excludes it on its
    // own (the same class of bug `aSweepThatStraddlesADismissalDoesNotBring
    // TheRowBack` guards against for Ignore).
    let store = temporaryStore()
    try store.save([watch("ninja"), watch("day9tv")])
    let model = model(store: store)
    let sweep = [
      WatchPollResult(login: "ninja", displayName: "Ninja", outcome: .found([archive("1")])),
      WatchPollResult(login: "day9tv", displayName: "Day9tv", outcome: .found([archive("2")])),
    ]
    model.apply(sweep)

    model.stopWatching("ninja")
    // The in-flight sweep lands after the stop, unchanged.
    model.apply(sweep)

    #expect(model.sections.map(\.login) == ["day9tv"])
  }

  @Test func stoppingAChannelDropsItsOwnDismissedIdsSoAReAddDoesNotHideThem() throws {
    // A stopped channel gets no more sweeps to let `apply`'s own
    // `formIntersection` drop its ids out of the overlay — left alone, they
    // would linger forever, and a later re-add whose first sweep reuses one
    // of those VOD ids would have a genuinely new archive hidden by a
    // dismissal earned by a watch that no longer exists.
    //
    // **Through `refresh()`, not a fresh `apply(_:)`** — re-sweeping after
    // the re-add would mask the exact bug this pins: `latest` still holds
    // the *original* sweep's entry for "1" throughout (untouched by
    // `stopWatching`, see its own comment), so the only thing standing
    // between that entry and the row it should now show again is whether
    // `dismissed` still contains "1". `refresh()` is what production calls
    // once the re-add's window closes, and the next real sweep can be up to
    // an hour away.
    let store = temporaryStore()
    try store.save([watch("ninja")])
    let model = model(store: store)
    model.apply([.init(login: "ninja", displayName: "Ninja", outcome: .found([archive("1")]))])
    model.ignore(archive("1"), from: "ninja")

    model.stopWatching("ninja")
    try store.save([watch("ninja")])
    model.refresh()

    #expect(model.sections.first(where: { $0.login == "ninja" })?.archives.map(\.id) == ["1"])
  }

  // MARK: - Re-reading the watch list on demand

  @Test func refreshShowsAChannelAddedToTheStoreAfterConstruction() throws {
    // `AddChannelModel` writes through its own `WatchStore`, a different
    // instance from the one this model reads through — nothing here notices
    // that write on its own. Without `refresh()`, a channel added from that
    // window stays invisible until the next hourly sweep, which is the exact
    // flow the Watching pane's toolbar button exists for appearing to do
    // nothing.
    let store = temporaryStore()
    try store.save([watch("ninja")])
    let model = model(store: store)
    #expect(model.sections.map(\.login) == ["ninja"])

    try store.save([watch("ninja"), watch("day9tv")])
    model.refresh()

    #expect(model.sections.map(\.login).sorted() == ["day9tv", "ninja"])
  }

  @Test func stopWatchingRefusesRatherThanOverwritingWhenTheStoreCannotBeRead() throws {
    // The same bug `AddChannelModelTests
    // .addRefusesRatherThanOverwritingWhenTheWatchListCannotBeRead` guards
    // against: a `try? store.load() ?? []` here would read the unreadable
    // file as "nothing is watched" and save a filtered list over it,
    // permanently losing every channel this call was never asked to touch.
    let store = try unreadableStore()
    defer { try? FileManager.default.removeItem(at: store.fileURL.deletingLastPathComponent()) }
    let model = model(store: store)

    model.stopWatching("ninja")

    #expect(model.stopWatchingFailure != nil, "the refusal must say why, not just dismiss")
    var isDirectory: ObjCBool = false
    let stillThere = FileManager.default.fileExists(
      atPath: store.fileURL.path, isDirectory: &isDirectory)
    #expect(stillThere && isDirectory.boolValue, "must refuse rather than save over what it could not read")
  }

  // MARK: - stopWatchingFailure is cleared at the right moments

  /// The bug: `stopWatchingFailure` used to clear only on a *later
  /// successful stop* — of any channel — which cut both ways. It survived a
  /// pane switch or an unrelated Ignore/Add indefinitely (nothing else ever
  /// touched it), yet a successful stop of a *different* channel cleared it
  /// while the login that actually failed was still watched, implying the
  /// problem had been resolved when it had not. `rebuild()` now clears it on
  /// every path that reaches it (`refresh()`, `apply(_:)`, `markSeen`, and a
  /// later `stopWatching` of any channel) — an honest "something else has
  /// happened since" rather than a specific, misleading claim.
  @Test func stopWatchingFailureIsClearedByAnyLaterActionNotJustAMatchingStop() throws {
    let file = URL.temporaryDirectory
      .appending(path: "watching-\(UUID().uuidString)")
      .appending(path: "watches.json")
    try FileManager.default.createDirectory(at: file, withIntermediateDirectories: true)
    let store = WatchStore(fileURL: file)
    let model = model(store: store)

    model.stopWatching("ninja")
    #expect(model.stopWatchingFailure != nil, "precondition: the refusal is visible")

    // Fixes the underlying store and takes some other, unrelated action —
    // standing in for switching away from the Watching pane and back, since
    // `refresh()` is what that re-appearance calls.
    try FileManager.default.removeItem(at: file)
    try store.save([watch("day9tv")])
    model.refresh()

    #expect(
      model.stopWatchingFailure == nil,
      "a later, unrelated action must not leave a stale refusal on screen indefinitely")
  }

  // MARK: - The class invariant, under random interleaving

  /// Both existing race tests (`aSweepThatStraddlesADismissalDoesNotBring
  /// TheRowBack`, `aSweepThatStraddlesAStopDoesNotResurrectTheStoppedChannel`)
  /// fake staleness by re-applying an *identical* payload — which pins one
  /// instance of the bug, not the property the class is supposed to have.
  /// This drives `apply`, `ignore`, `add`, `stopWatching`, `refresh`, and a
  /// write through a second `WatchStore` (standing in for `AddChannelModel`
  /// writing the same file) in a random order, and checks two things after
  /// *every* step rather than only at the end:
  ///
  /// 1. `sections` and `watches` name exactly the same logins — no section
  ///    for a channel that is not watched, no watched channel missing one.
  /// 2. A watched channel's archives are exactly its newest sweep's findings,
  ///    minus whatever its own persisted `seen` set has since gained.
  ///
  /// Deliberately does not inject a failed store write anywhere in the
  /// interleaving — that path (`dismissed`'s one remaining job) already has
  /// its own dedicated tests above. Every write here succeeds, so invariant 2
  /// never has to account for "pending a failed write" to hold.
  @Test func watchesIsAlwaysTheSpineUnderRandomInterleaving() throws {
    let seed: UInt64 = 0x5EED_C0FFEE
    var rng = SeededGenerator(seed: seed)

    let store = temporaryStore()
    let loginPool = ["ninja", "day9tv", "asmongold"]
    // Scoped per login, deliberately: real Twitch archive ids are unique
    // platform-wide, so two different channels never share one. `dismissed`
    // is not scoped by login (it never has been — see its own doc comment),
    // and sharing one raw id pool across logins here would manufacture
    // cross-channel id collisions no real sweep could ever produce, hiding
    // one channel's finding behind an unrelated channel's dismissal for a
    // reason that has nothing to do with the property this test checks.
    func ids(for login: String) -> [String] { (1...4).map { "\(login)-\($0)" } }

    try store.save([watch("ninja"), watch("day9tv")])
    let model = model(store: store)

    // This test's own record of what the last sweep actually handed
    // `apply(_:)` for each login — the ground truth invariant 2 checks
    // against. Never cleared by a stop: a real `latest` array is not either
    // (see `WatchingModel.stopWatching`'s own comment), so a channel that is
    // stopped and re-added is checked against the same stale sweep the model
    // itself would still be holding.
    var lastFound: [String: [ChannelArchive]] = [:]
    var lastFailed: Set<String> = []

    func currentLogins() throws -> [String] { try store.load().map(\.login) }

    func performSweep() throws {
      // One `apply(_:)` call for every currently watched login, exactly the
      // shape `WatchPoller.sweep` produces — never one call per login.
      // `dismissed.formIntersection(found)` inside `apply(_:)` only narrows
      // against the ids the *whole* array carries; splitting this into one
      // call per login would starve that intersection of every other
      // login's ids on each call and shrink `dismissed` for reasons that
      // have nothing to do with a real sweep.
      //
      // Mirrors `WatchPoll.sweep` in the other respect too: a raw fetch per
      // login, immediately narrowed through that login's *own*
      // `findings(in:)` — against whatever `seen` was at this exact moment
      // — before the result ever reaches `apply(_:)`. `lastFound` records
      // that *carried*, already-narrowed list, not the raw fetch: "the
      // newest sweep carries it" is about what the sweep actually reported,
      // and a later re-add with a fresh, emptied `seen` cannot retroactively
      // widen what an earlier, now-stale sweep once said. That is exactly
      // the asymmetry the sixth bug turned on, so the ground truth here has
      // to preserve it.
      var results: [WatchPollResult] = []
      for watchEntry in try store.load() {
        if Bool.random(using: &rng) {
          let raw = ids(for: watchEntry.login).filter { _ in Bool.random(using: &rng) }.map(archive)
          let carried = watchEntry.findings(in: raw)
          results.append(.init(login: watchEntry.login, displayName: watchEntry.displayName,
                               outcome: .found(carried)))
          lastFound[watchEntry.login] = carried
          lastFailed.remove(watchEntry.login)
        } else {
          results.append(.init(login: watchEntry.login, displayName: watchEntry.displayName,
                               outcome: .failed(.noSuchChannel)))
          lastFailed.insert(watchEntry.login)
        }
      }
      // `apply(_:)` sets `latest = results` — wholesale, not merged (its own
      // doc comment) — so a login this sweep does not cover (because it was
      // unwatched when `WatchPoll.sweep` ran) loses its entry outright, not
      // only until a later sweep adds it back. A completely stale entry
      // surviving *through* a real sweep that had every chance to refresh it
      // is not what "the newest sweep carries it" means; the ground truth
      // has to go stale the same way `latest` actually does.
      let covered = Set(results.map(\.login))
      for login in lastFound.keys where !covered.contains(login) { lastFound[login] = nil }
      lastFailed.formIntersection(covered)
      model.apply(results)
    }

    func performIgnoreOrAdd() throws {
      guard let login = try currentLogins().randomElement(using: &rng),
            let id = ids(for: login).randomElement(using: &rng)
      else { return }
      if Bool.random(using: &rng) {
        model.ignore(archive(id), from: login)
      } else {
        model.add(archive(id), from: login)
      }
    }

    func performStop() throws {
      guard let login = try currentLogins().randomElement(using: &rng) else { return }
      model.stopWatching(login)
    }

    func performForeignWrite() throws {
      // Stands in for `AddChannelModel` writing `watches.json` through its
      // own, separate `WatchStore` instance. Only ever adds — the model's
      // own doc comment is explicit that `WatchingModel` is "the only writer"
      // that ever *removes* a watch (`stopWatching`, which is also the only
      // place that cleans `dismissed` of a removed watch's ids); a foreign
      // write pruning some other channel here would be testing a shape
      // `AddChannelModel` never actually takes; `stopWatching` above is the
      // only removal path this interleaving needs to cover.
      let foreign = WatchStore(fileURL: store.fileURL)
      var current = try foreign.load()
      if let addable = loginPool.first(where: { candidate in
        !current.contains { $0.login == candidate }
      }) {
        current.append(watch(addable))
        try foreign.save(current)
      }
    }

    func checkInvariants(step: Int) throws {
      let watchedLogins = Set(model.watches.map(\.login))
      #expect(Set(model.sections.map(\.login)) == watchedLogins,
        "seed \(seed) step \(step): sections must name exactly the watched logins")

      for watchEntry in model.watches {
        let expectedIDs: Set<String>
        if lastFailed.contains(watchEntry.login) {
          expectedIDs = []
        } else if let carried = lastFound[watchEntry.login] {
          expectedIDs = Set(carried.map(\.id)).subtracting(watchEntry.seen)
        } else {
          expectedIDs = []
        }
        let actualIDs = Set(
          model.sections.first(where: { $0.login == watchEntry.login })?.archives.map(\.id) ?? [])
        #expect(actualIDs == expectedIDs,
          "seed \(seed) step \(step) login \(watchEntry.login): archives must be exactly the newest sweep's findings minus seen")
      }
    }

    try checkInvariants(step: 0)
    for step in 1...300 {
      switch Int.random(in: 0..<6, using: &rng) {
      case 0, 1: try performSweep()
      case 2, 3: try performIgnoreOrAdd()
      case 4: try performStop()
      default: try performForeignWrite()
      }
      // `refresh()` is folded in here rather than its own case so a stray
      // `AddChannelModel`-shaped write always gets picked up promptly, the
      // same as production wiring it to the window closing.
      if step.isMultiple(of: 7) { model.refresh() }
      try checkInvariants(step: step)
    }
  }

  /// The sixth bug, confirmed live. `stopWatching` used to remove the login's
  /// own entry from `latest` outright — irreversible — while `stoppedLogins`
  /// (a reversible tombstone `refreshWatches()` lifted the moment the login
  /// was back in the file) guarded the same race with the opposite lifetime.
  /// Re-adding a stopped channel lifted the reversible guard and exposed the
  /// irreversible one: the channel's own last-known findings were gone for
  /// good, so it fell into the never-polled branch — `archives: []`,
  /// `failure: nil` — reading as "nothing new" when the re-add (with "All
  /// available") asked for the whole back catalogue.
  ///
  /// **Through `refresh()`, not `apply(_:)`.** `stoppingAChannelDropsItsOwn
  /// DismissedIdsSoAReAddDoesNotHideThem` above walks the same sequence but
  /// recovers by re-applying the sweep — a path production never takes after
  /// a re-add; the window closing calls `refresh()` (see `OxbowApp`), and the
  /// next real sweep is up to an hour away. This is the sequence that
  /// actually happens.
  @Test func reAddingAStoppedChannelAndRefreshingShowsItsLastFindingsAgain() throws {
    let store = temporaryStore()
    try store.save([watch("ninja")])
    let model = model(store: store)
    model.apply([.init(login: "ninja", displayName: "Ninja",
                       outcome: .found([archive("1"), archive("2")]))])

    model.stopWatching("ninja")
    // Re-add with "All available" — a fresh `Watch` with an empty `seen`,
    // the same shape `AddChannelModel.add(_:)` writes for that scope.
    try store.save([watch("ninja")])
    model.refresh()

    #expect(
      model.sections.first(where: { $0.login == "ninja" })?.archives.map(\.id).sorted()
        == ["1", "2"],
      "the re-added channel's own last sweep must still be there once it is watched again")
  }
}

/// A tiny deterministic PRNG so a failure found by chance is reproducible —
/// `SystemRandomNumberGenerator` cannot be seeded, and reproducing exactly
/// the interleaving that broke the invariant is the entire point of fuzzing
/// it. (splitmix64.)
private struct SeededGenerator: RandomNumberGenerator {
  private var state: UInt64
  init(seed: UInt64) { state = seed == 0 ? 0xdeadbeef : seed }
  mutating func next() -> UInt64 {
    state &+= 0x9E37_79B9_7F4A_7C15
    var z = state
    z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
    z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
    return z ^ (z >> 31)
  }
}

/// A reference box so an escaping closure's effect is observable from a test.
@MainActor private final class OpenedBox {
  var id: String?
}
