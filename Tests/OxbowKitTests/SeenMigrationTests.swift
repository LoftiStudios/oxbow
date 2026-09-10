import Foundation
import Testing
@testable import OxbowKit

@Suite("Seen migration")
struct SeenMigrationTests {

  private func watch(_ login: String, seen: Set<String>) -> Watch {
    Watch(
      login: login, displayName: login,
      settings: .init(destinationPath: "/tmp", qualityCap: .p720,
                      output: .video, chatSize: .large),
      downloadsAutomatically: false, seen: seen)
  }

  /// A bare id is all that was ever stored, so a bare id is all that comes
  /// out — with a login, which is the one fact the watch does carry.
  @Test("every seen id becomes a skipped entry carrying its login")
  func seenBecomesSkipped() {
    let library = SeenMigration.migrate(
      watches: [watch("wheelyf", seen: ["1", "2"])], into: VideoLibrary())

    #expect(library.watchStates["1"] == .skipped)
    #expect(library.watchStates["2"] == .skipped)
    #expect(library.videos["1"]?.login == "wheelyf")
    #expect(library.videos["1"]?.title == nil)
  }

  /// Running twice must not undo real progress. A migrated `skipped` entry
  /// that has since become `downloaded` stays downloaded.
  @Test("migration never overwrites a state already recorded")
  func migrationIsIdempotent() {
    var library = VideoLibrary()
    library.record(VideoRecord(id: "1", login: "wheelyf", title: "real"))
    library.setState(.downloaded, for: "1")

    let migrated = SeenMigration.migrate(
      watches: [watch("wheelyf", seen: ["1"])], into: library)

    #expect(migrated.watchStates["1"] == .downloaded)
    #expect(migrated.videos["1"]?.title == "real")
  }

  @Test("a watch with an empty seen-set contributes nothing")
  func emptySeenIsNoOp() {
    let library = SeenMigration.migrate(
      watches: [watch("wheelyf", seen: [])], into: VideoLibrary())

    #expect(library == VideoLibrary())
  }

  @Test("two channels do not collide")
  func twoChannels() {
    let library = SeenMigration.migrate(
      watches: [watch("wheelyf", seen: ["1"]), watch("avabamby", seen: ["2"])],
      into: VideoLibrary())

    #expect(library.videos["1"]?.login == "wheelyf")
    #expect(library.videos["2"]?.login == "avabamby")
    #expect(library.seenIDs(forLogin: "wheelyf") == ["1"])
  }
}
