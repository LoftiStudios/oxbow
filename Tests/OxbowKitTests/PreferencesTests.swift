import Foundation
import Testing
@testable import OxbowKit

@Suite("Preferences")
struct PreferencesTests {

  /// Removes every scratch suite this test created, once the test itself is
  /// torn down. Swift Testing has no `tearDown`; a plain class's `deinit`
  /// is the idiomatic replacement, and a fresh `PreferencesTests` (with a
  /// fresh `janitor`) is constructed for every `@Test`, so one test's
  /// cleanup cannot affect another's. Without this, every call to
  /// `defaults()` below leaves a `.plist` behind in
  /// `~/Library/Preferences` — real disk litter, not a test-only cost.
  private final class SuiteJanitor {
    var names: [String] = []
    deinit {
      for name in names { UserDefaults.standard.removePersistentDomain(forName: name) }
    }
  }

  private let janitor = SuiteJanitor()

  private func defaults() throws -> UserDefaults {
    let name = "PreferencesTests-\(UUID().uuidString)"
    janitor.names.append(name)
    return try #require(UserDefaults(suiteName: name))
  }

  private let home = URL(filePath: "/Users/tester")

  private func store(
    _ defaults: UserDefaults,
    directoryExists: @escaping (URL) -> Bool = { _ in true }) -> Preferences
  {
    Preferences(defaults: defaults, homeDirectory: home, directoryExists: directoryExists)
  }

  // MARK: - Factory values

  /// An app nobody has configured behaves exactly as it did before this
  /// feature existed.
  @Test func factoryValuesMatchTheIntakesOldStartingState() throws {
    let store = store(try defaults())
    #expect(store.destination == home.appending(path: "Downloads"))
    #expect(store.qualityCap == .best)
    #expect(store.output == .videoWithChat)
    #expect(store.chatSize == .medium)
  }

  @Test func hasSavedDefaultsStartsFalse() throws {
    #expect(store(try defaults()).hasSavedDefaults == false)
  }

  // MARK: - Round trips

  @Test func everyFieldSurvivesANewInstanceOverTheSameDefaults() throws {
    let defaults = try defaults()
    var writer = store(defaults)
    writer.destination = URL(filePath: "/Volumes/Archive/VODs")
    writer.qualityCap = .p720
    writer.output = .video
    writer.chatSize = .large

    let reader = store(defaults)
    #expect(reader.destination == URL(filePath: "/Volumes/Archive/VODs"))
    #expect(reader.qualityCap == .p720)
    #expect(reader.output == .video)
    #expect(reader.chatSize == .large)
  }

  // MARK: - optionsPanelIsExpanded

  @Test func optionsPanelIsExpandedDefaultsToTrue() throws {
    #expect(store(try defaults()).optionsPanelIsExpanded)
  }

  @Test func optionsPanelIsExpandedRoundTrips() throws {
    let defaults = try defaults()
    var writer = store(defaults)
    writer.optionsPanelIsExpanded = false
    #expect(store(defaults).optionsPanelIsExpanded == false)
  }

  /// Spec: collapsing the panel is not expressing a preference about
  /// downloads, so it must not set the same flag a real save does — or the
  /// Settings window would start claiming defaults nobody chose.
  @Test func settingOptionsPanelIsExpandedDoesNotSetHasSavedDefaults() throws {
    let defaults = try defaults()
    var writer = store(defaults)
    writer.optionsPanelIsExpanded = false
    #expect(store(defaults).hasSavedDefaults == false)
  }

  // MARK: - hasSavedDefaults

  /// Spec §2.4. Saving values identical to the factory ones still counts as
  /// having expressed a preference — comparing against factory would call
  /// that user a first-timer forever.
  @Test func writingAFactoryIdenticalValueStillSetsTheFlag() throws {
    let defaults = try defaults()
    var writer = store(defaults)
    writer.qualityCap = .best
    #expect(store(defaults).hasSavedDefaults)
  }

  @Test func anyFieldSetsTheFlag() throws {
    for mutate in [
      { (p: inout Preferences) in p.destination = URL(filePath: "/tmp/x") },
      { (p: inout Preferences) in p.qualityCap = .p480 },
      { (p: inout Preferences) in p.output = .video },
      { (p: inout Preferences) in p.chatSize = .small },
    ] {
      let defaults = try defaults()
      var writer = store(defaults)
      mutate(&writer)
      #expect(store(defaults).hasSavedDefaults)
    }
  }

  // MARK: - Restore

  @Test func restoreReturnsEveryFieldAndClearsTheFlag() throws {
    let defaults = try defaults()
    var store = store(defaults)
    store.destination = URL(filePath: "/Volumes/Archive")
    store.qualityCap = .p360
    store.output = .video
    store.chatSize = .large
    store.optionsPanelIsExpanded = false

    store.restoreDefaults()

    #expect(store.destination == home.appending(path: "Downloads"))
    #expect(store.qualityCap == .best)
    #expect(store.output == .videoWithChat)
    #expect(store.chatSize == .medium)
    #expect(store.optionsPanelIsExpanded)
    #expect(store.hasSavedDefaults == false)
  }

  // MARK: - A destination that no longer resolves

  /// Spec §4.2. Unmounted volume, deleted folder. The disk preflight measures
  /// the volume the destination sits on, so a silent fallback would change
  /// what the estimate means without changing what it says.
  @Test func aMissingDestinationFallsBackAndSaysSo() throws {
    let defaults = try defaults()
    var writer = store(defaults)
    writer.destination = URL(filePath: "/Volumes/Unplugged/VODs")

    let reader = store(defaults, directoryExists: { $0.path != "/Volumes/Unplugged/VODs" })
    #expect(reader.destination == home.appending(path: "Downloads"))
    #expect(reader.storedDestinationIsMissing)
  }

  @Test func aPresentDestinationReportsNothingMissing() throws {
    let defaults = try defaults()
    var writer = store(defaults)
    writer.destination = URL(filePath: "/Volumes/Archive/VODs")
    #expect(store(defaults).storedDestinationIsMissing == false)
  }

  /// Nothing stored is not the same as something stored and gone.
  @Test func anUnconfiguredStoreReportsNothingMissing() throws {
    #expect(store(try defaults(), directoryExists: { _ in false }).storedDestinationIsMissing == false)
  }
}
