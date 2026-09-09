import Foundation

/// Turns each watch's stored `seen` set into watch-state entries, once.
///
/// **A one-way trip that does not have to be pretty**
/// (`docs/design/channel-history.md` §3.2). The feature has not shipped, there
/// is no installed base, and the only data in existence is disposable.
///
/// Each id becomes a `skipped` entry with **no video facts**, because none were
/// ever stored and none can be recovered — `seen` was a set of bare strings.
/// Ids still on Twitch pick up their title and date on the next sweep. Ids
/// already expired stay bare numbers forever.
///
/// The login is the one fact a watch does carry about its ids, and recording it
/// is what lets `VideoLibrary.seenIDs(forLogin:)` scope correctly afterwards.
///
/// **Idempotent, and that is not decoration.** This runs at launch; a state
/// already recorded is real progress and must survive a second run, or an
/// upgrade would reset every downloaded archive to `skipped` and hide it.
public enum SeenMigration {

  public static func migrate(watches: [Watch], into library: VideoLibrary) -> VideoLibrary {
    var migrated = library

    for watch in watches {
      for id in watch.seen {
        // Facts are merged, so a row that already has a title keeps it.
        migrated.record(VideoRecord(id: id, login: watch.login))
        // State is not: an existing state is the newer truth.
        if migrated.watchStates[id] == nil {
          migrated.setState(.skipped, for: id)
        }
      }
    }

    return migrated
  }
}
