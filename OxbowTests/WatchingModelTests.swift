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

  @Test func sectionsMirrorTheSweep() {
    let model = model(store: temporaryStore())
    model.apply([
      .init(login: "ninja", displayName: "Ninja", outcome: .found([archive("1"), archive("2")])),
      .init(login: "day9tv", displayName: "Day9tv", outcome: .found([archive("3")]))])

    #expect(model.sections.map(\.login) == ["ninja", "day9tv"])
    #expect(model.sections[0].archives.map(\.id) == ["1", "2"])
    #expect(model.unreadCount == 3)
  }

  @Test func aFailedChannelKeepsItsReasonAndIsNotCountedAsUnread() {
    // Section 7: a failure must read as a failure, never as an empty list.
    let model = model(store: temporaryStore())
    model.apply([.init(login: "gone", displayName: "Gone", outcome: .failed(.noSuchChannel))])

    #expect(model.sections[0].failure != nil)
    #expect(model.sections[0].archives.isEmpty)
    #expect(model.unreadCount == 0)
  }

  @Test func aChannelWithNothingNewIsNotShownAsAFailure() {
    let model = model(store: temporaryStore())
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

  @Test func aDismissalDropsOutOfTheOverlayOnceTheArchiveStopsAppearing() throws {
    // A sweep computed after the write no longer carries the dismissed id at
    // all, so it can drop out of the overlay safely — the set stays bounded
    // instead of growing forever, and a genuinely new archive that reuses the
    // id later is not hidden permanently by a stale dismissal.
    let store = temporaryStore()
    try store.save([watch("ninja")])
    let model = model(store: store)
    model.apply([.init(login: "ninja", displayName: "Ninja", outcome: .found([archive("1")]))])
    model.ignore(archive("1"), from: "ninja")

    model.apply([.init(login: "ninja", displayName: "Ninja", outcome: .found([]))])
    model.apply([.init(login: "ninja", displayName: "Ninja", outcome: .found([archive("1")]))])

    #expect(model.sections[0].archives.map(\.id) == ["1"])
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
    let store = temporaryStore()
    try store.save([watch("ninja")])
    let model = model(store: store)
    model.apply([.init(login: "ninja", displayName: "Ninja", outcome: .found([archive("1")]))])
    model.ignore(archive("1"), from: "ninja")

    model.stopWatching("ninja")
    try store.save([watch("ninja")])
    model.apply([.init(login: "ninja", displayName: "Ninja", outcome: .found([archive("1")]))])

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
}

/// A reference box so an escaping closure's effect is observable from a test.
@MainActor private final class OpenedBox {
  var id: String?
}
