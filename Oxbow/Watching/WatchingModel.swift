import Foundation
import Observation
import OxbowKit

/// The Watching list: what the last sweep found, and the two things a person
/// can do about it.
///
/// **The only writer to `watches.json`.** Polling is read-only by design
/// (`docs/design/channel-watching.md` §4) — the seen-set changes when someone
/// Adds or Ignores, and nowhere else. Keeping both writes here is what stops
/// the poller and the UI racing over the same file.
@MainActor
@Observable
final class WatchingModel {

  /// One channel's part of the list.
  struct Section: Identifiable, Equatable {
    var login: String
    var displayName: String
    var archives: [ChannelArchive]
    /// Why this channel produced nothing, when that is the reason.
    ///
    /// Distinct from `archives.isEmpty`, and that distinction is the point:
    /// §7 requires a parse failure to read as a visible error rather than as
    /// "no new videos". A quiet channel has a nil failure and an empty list;
    /// a broken one has a message.
    var failure: String?
    /// What this channel is frozen to download at, read in
    /// `IntakeModel.optionsSummary`'s own register — same fields, same
    /// separator, same terse phrasing — so a quality cap or a destination
    /// does not read differently depending on which window shows it.
    ///
    /// `docs/design/channel-watching.md` §3.2: a watch's settings are frozen
    /// at add time and never surface again on their own, so this is the one
    /// place left that can still answer "what did I actually sign this
    /// channel up for?"
    var settingsSummary: String
    /// Whether this channel fetches on its own rather than only telling.
    ///
    /// Off by default and consequential (§2, §11.1) — a watch that has it on
    /// has to look different from one that does not, or the one control that
    /// matters most is also the one nobody can see they turned on. Nothing
    /// downloads automatically yet (that is a later stage); this shows the
    /// stored intent, not a running behaviour.
    var downloadsAutomatically: Bool

    var id: String { login }
  }

  private(set) var sections: [Section] = []

  /// The current watch list, kept in step with `watches.json` so a section
  /// can show what its channel is set to, and so a channel that has never
  /// been polled — just added, or waiting for its first sweep — still gets
  /// one. Refreshed at the top of every `rebuild()`, not only at `init`,
  /// because the file can gain or lose a channel (`Add Channel`,
  /// `stopWatching`) between sweeps.
  private(set) var watches: [Watch] = []

  /// Findings not yet acted on. Failures deliberately do not count — a badge
  /// that includes them would tell someone there is something to download
  /// when there is something to fix.
  var unreadCount: Int { sections.reduce(0) { $0 + $1.archives.count } }

  private let store: WatchStore
  private let openIntake: (ChannelArchive, Watch) -> Void

  /// Archive ids acted on since the last sweep.
  ///
  /// **This is why Add and Ignore feel instant.** `WatchPoller.results` is a
  /// snapshot taken against the seen-set as it stood at sweep time, so
  /// persisting a dismissal does not change it — without this overlay the row
  /// would sit there until the next sweep, up to an hour of a button that
  /// appears to do nothing.
  ///
  /// **Not cleared wholesale by `apply(_:)`.** `sweep` reads the seen-set once
  /// up front and then makes slow, sequential per-channel calls, so a sweep in
  /// flight when someone dismisses a row can finish with results computed
  /// before that write — still containing the just-dismissed archive. Wiping
  /// the overlay on every `apply` would let that stale result put the row
  /// back. Instead `apply(_:)` narrows `dismissed` to the ids still present in
  /// the incoming results: an id absent from the new sweep was one the sweep
  /// read after the write, so it drops out on its own; an id still present
  /// means the sweep straddled the write, so the overlay keeps hiding it until
  /// a sweep finally starts after the dismissal landed.
  private var dismissed: Set<String> = []

  /// The latest sweep, before the overlay is subtracted.
  private var latest: [WatchPollResult] = []

  /// Logins `stopWatching` has removed, kept so `rebuild()` can refuse to
  /// resurrect them.
  ///
  /// **Why this exists rather than trusting `watches` membership alone.**
  /// `WatchPoller.sweep` is sequential and can run for minutes, so a sweep
  /// already in flight when someone chooses Stop Watching can still land
  /// afterwards via `apply(_:)` — which replaces `latest` wholesale — still
  /// carrying that channel's own entry. `rebuild()` excludes any login in
  /// this set from `latest` outright, so that stale sweep is ignored rather
  /// than rendered. `refreshWatches()` lifts the exclusion the moment the
  /// login is back in `watches.json`, so re-adding a stopped channel is not
  /// permanent.
  private var stoppedLogins: Set<String> = []

  /// Set when Stop Watching refused rather than removing anything. The same
  /// idiom as `AddChannelModel.addFailure`: a context menu action has no
  /// return value for a caller to inspect, so the reason has to land
  /// somewhere a view can read it after the fact.
  private(set) var stopWatchingFailure: String?

  init(store: WatchStore, openIntake: @escaping (ChannelArchive, Watch) -> Void) {
    self.store = store
    self.openIntake = openIntake
    // Populates `sections` from whatever is already watched before the first
    // sweep ever lands — requirement 1's "never polled" case starts the
    // instant a channel is added, not once `WatchPoller` gets around to it.
    rebuild()
  }

  /// Replaces the list with a new sweep.
  ///
  /// Wholesale, not merged: the inbox is derived rather than accumulated
  /// (§4), so an archive that has expired since the last sweep should stop
  /// appearing rather than linger as a row nothing can download.
  func apply(_ results: [WatchPollResult]) {
    latest = results

    let found = results.reduce(into: Set<String>()) { ids, result in
      if case .found(let archives) = result.outcome {
        ids.formUnion(archives.map(\.id))
      }
    }
    dismissed.formIntersection(found)

    rebuild()
  }

  func ignore(_ archive: ChannelArchive, from login: String) {
    markSeen(archive.id, in: login)
  }

  /// Marks the archive seen and hands it to intake, prefilled.
  ///
  /// **Seen on Add, not on the eventual download.** The watch's job is to stop
  /// offering something once it has been answered, and someone who adds a VOD
  /// and then abandons the intake form has still answered it. Re-offering it
  /// on the next sweep would be the app asking a question it was already told
  /// the answer to.
  func add(_ archive: ChannelArchive, from login: String) {
    guard let watch = markSeen(archive.id, in: login) else { return }
    openIntake(archive, watch)
  }

  /// Persists the id into the channel's seen-set and hides its row. Returns
  /// the watch it belonged to, or nil if the channel is no longer watched —
  /// which is not an error: the file can change under a list already on
  /// screen.
  @discardableResult
  private func markSeen(_ id: String, in login: String) -> Watch? {
    dismissed.insert(id)
    rebuild()

    guard var current = try? store.load(),
          let index = current.firstIndex(where: { $0.login == login })
    else { return nil }

    current[index] = current[index].marking([id])
    // Best effort. `dismissed` was already updated above, before this write
    // was attempted, and nothing rolls it back if the write fails — so a
    // failed save does not cost "one re-offer on the next sweep": the row
    // stays hidden by the in-memory overlay for the rest of this session (its
    // id keeps coming back from every sweep, and `apply`'s
    // `formIntersection` keeps retaining it), and the re-offer only arrives
    // on the next launch, once `dismissed` itself is gone. That is still a
    // far better outcome than an alert about a file the user has no way to
    // fix, on a list they are in the middle of triaging.
    try? store.save(current)
    return current[index]
  }

  /// Removes `login`'s watch and persists what is left, touching nothing
  /// else about the other channels' settings or seen-sets.
  ///
  /// **Does not delete anything already downloaded.** This edits
  /// `watches.json` — the list of channels being watched — never a file a
  /// past download produced. Stopping a watch and deleting its archive are
  /// two different decisions, and this makes only the first one.
  ///
  /// **Refuses rather than overwriting when the store cannot be read** — the
  /// same rule `AddChannelModel.add()` follows, guarding the identical bug:
  /// `try? store.load() ?? []` cannot tell "nothing else is watched" apart
  /// from "the file could not be read", and saving a filtered list built
  /// from the wrong one of those would silently erase every other channel
  /// this call was never asked to touch.
  func stopWatching(_ login: String) {
    let existing: [Watch]
    do {
      existing = try store.load()
    } catch {
      stopWatchingFailure = """
        Oxbow could not read the watch list, so \(login) was not stopped. \
        \(error.localizedDescription)
        """
      return
    }

    do {
      try store.save(existing.filter { $0.login != login })
    } catch {
      stopWatchingFailure = "Oxbow could not save the watch list: \(error.localizedDescription)"
      return
    }

    stopWatchingFailure = nil

    // A stopped channel's own entry in the last sweep must not resurrect its
    // section on the next `rebuild()` — see `stoppedLogins`'s own doc
    // comment for why this, rather than `watches` membership alone, is what
    // that guard checks.
    stoppedLogins.insert(login)

    // This channel's own ids would otherwise linger in the overlay forever:
    // `apply(_:)`'s `formIntersection` only drops an id once a sweep
    // computed *after* the write stops carrying it, and a stopped channel
    // gets no more sweeps to make that happen. Left alone, a later re-add
    // whose first sweep happens to reuse one of those VOD ids would have a
    // genuinely new archive hidden by a dismissal earned by a watch that no
    // longer exists.
    if let lastResult = latest.first(where: { $0.login == login }),
       case .found(let archives) = lastResult.outcome {
      dismissed.subtract(archives.map(\.id))
    }

    latest.removeAll { $0.login == login }
    rebuild()
  }

  /// Re-reads `watches.json` and rebuilds `sections` from it.
  ///
  /// **Why a caller ever needs to ask for this.** `sections` otherwise only
  /// changes when a sweep lands (`apply(_:)`) or this model makes its own
  /// write (`markSeen`, `stopWatching`) — nothing here notices a write made
  /// by a *different* `WatchStore` instance, such as `AddChannelWindow`'s.
  /// Without an explicit re-read, a channel added from that window stays
  /// invisible until the next hourly sweep, which is the exact flow the
  /// toolbar button exists for appearing to do nothing. `QueueView` calls
  /// this when the Watching pane appears, and `OxbowApp` calls it once the
  /// Add Channel window closes — see each call site's own comment.
  func refresh() {
    rebuild()
  }

  /// Re-reads the watch list so `rebuild()` can show every channel actually
  /// being watched, including one no sweep has produced a result for yet —
  /// added moments ago, or resolved by `stopWatching` just above.
  ///
  /// Best effort: a failed read leaves `watches` exactly as it was, the same
  /// posture `markSeen`'s write takes — every write this model makes already
  /// refuses outright rather than leaving a state this would need to
  /// recover from.
  private func refreshWatches() {
    if let loaded = try? store.load() {
      watches = loaded
      // A login back in the watch list is no longer "stopped" — this is what
      // lets stopping a channel and then re-adding it undo the exclusion
      // `rebuild()` applies below, rather than leaving that channel invisible
      // forever.
      stoppedLogins.subtract(loaded.map(\.login))
    }
  }

  private func rebuild() {
    refreshWatches()

    var represented: Set<String> = []
    var built: [Section] = latest.compactMap { result in
      // Excludes a stopped channel's own entry even when a stale, in-flight
      // sweep still carries it — see `stoppedLogins`'s own doc comment.
      guard !stoppedLogins.contains(result.login) else { return nil }
      represented.insert(result.login)
      let summary = settingsSummary(forLogin: result.login)
      let automatic = downloadsAutomatically(forLogin: result.login)
      switch result.outcome {
      case .found(let archives):
        return Section(
          login: result.login, displayName: result.displayName,
          archives: archives.filter { !dismissed.contains($0.id) }, failure: nil,
          settingsSummary: summary, downloadsAutomatically: automatic)
      case .failed(let error):
        return Section(
          login: result.login, displayName: result.displayName,
          archives: [], failure: error.localizedDescription,
          settingsSummary: summary, downloadsAutomatically: automatic)
      }
    }

    // Every watched channel the sweep above didn't already account for —
    // never polled, or waiting on its first sweep since launch — still gets
    // a section (requirement 1), rather than staying invisible until a
    // sweep finally reaches it.
    for watch in watches where !represented.contains(watch.login) {
      built.append(Section(
        login: watch.login, displayName: watch.displayName,
        archives: [], failure: nil,
        settingsSummary: settingsSummary(for: watch.settings),
        downloadsAutomatically: watch.downloadsAutomatically))
    }

    sections = built
  }

  private func settingsSummary(forLogin login: String) -> String {
    guard let watch = watches.first(where: { $0.login == login }) else { return "" }
    return settingsSummary(for: watch.settings)
  }

  private func downloadsAutomatically(forLogin login: String) -> Bool {
    watches.first(where: { $0.login == login })?.downloadsAutomatically ?? false
  }

  /// `IntakeModel.optionsSummary`'s own register, applied to a watch's
  /// frozen settings instead of one intake submission: the output first
  /// (folded with the chat size, when it applies), the quality cap, then the
  /// destination — the same order, the same "·" separator, the same terse
  /// phrasing, so a person does not learn a second vocabulary for the same
  /// four settings depending on which window shows them.
  private func settingsSummary(for settings: Watch.Settings) -> String {
    let outputLabel: String
    switch settings.output {
    case .videoWithChat: outputLabel = "Video + chat"
    case .video: outputLabel = "Video"
    }

    var summary = "\(outputLabel) · \(settings.qualityCap.label)"
    // Chat size is meaningless when nothing renders chat — `IntakeWindow`
    // hides its own picker on the same condition
    // (`IntakeModel.withholdsChatSizeFromSave`), so this withholds it from
    // the summary line for the identical reason.
    if settings.output == .videoWithChat {
      summary += " · \(settings.chatSize.rawValue.capitalized) chat"
    }
    summary += " · \(settings.destination.lastPathComponent)"
    return summary
  }
}
