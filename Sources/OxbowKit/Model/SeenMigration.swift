import Foundation

/// Migrates legacy seen IDs to skipped entries scoped by watch login, without inventing missing
/// video facts. Preserves existing facts and states so repeated launch migrations cannot reset
/// progress.
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
