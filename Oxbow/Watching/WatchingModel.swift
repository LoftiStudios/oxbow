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

    var id: String { login }
  }

  private(set) var sections: [Section] = []

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
  /// appears to do nothing. Cleared by `apply(_:)`, because a fresh sweep has
  /// already re-read the persisted seen-set and excluded them itself.
  private var dismissed: Set<String> = []

  /// The latest sweep, before the overlay is subtracted.
  private var latest: [WatchPollResult] = []

  init(store: WatchStore, openIntake: @escaping (ChannelArchive, Watch) -> Void) {
    self.store = store
    self.openIntake = openIntake
  }

  /// Replaces the list with a new sweep.
  ///
  /// Wholesale, not merged: the inbox is derived rather than accumulated
  /// (§4), so an archive that has expired since the last sweep should stop
  /// appearing rather than linger as a row nothing can download.
  func apply(_ results: [WatchPollResult]) {
    latest = results
    dismissed.removeAll()
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

    guard var watches = try? store.load(),
          let index = watches.firstIndex(where: { $0.login == login })
    else { return nil }

    watches[index] = watches[index].marking([id])
    // Best effort: a failed write costs one re-offer on the next sweep, which
    // is a far better outcome than an alert about a file the user has no way
    // to fix, on a list they are in the middle of triaging.
    try? store.save(watches)
    return watches[index]
  }

  private func rebuild() {
    sections = latest.map { result in
      switch result.outcome {
      case .found(let archives):
        Section(
          login: result.login, displayName: result.displayName,
          archives: archives.filter { !dismissed.contains($0.id) }, failure: nil)
      case .failed(let error):
        Section(
          login: result.login, displayName: result.displayName,
          archives: [], failure: error.localizedDescription)
      }
    }
  }
}
