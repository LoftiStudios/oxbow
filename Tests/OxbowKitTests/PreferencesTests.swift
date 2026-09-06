import Foundation
import Testing
@testable import OxbowKit

@Suite("Preferences")
struct PreferencesTests {

  private let home = URL(filePath: "/Users/tester")

  private func store(
    _ preferenceStore: PreferenceStore,
    directoryExists: @escaping (URL) -> Bool = { _ in true }) -> Preferences
  {
    Preferences(store: preferenceStore, homeDirectory: home, directoryExists: directoryExists)
  }

  // MARK: - Factory values

  /// An app nobody has configured behaves exactly as it did before this
  /// feature existed.
  @Test func factoryValuesMatchTheIntakesOldStartingState() throws {
    let store = store(InMemoryPreferenceStore())
    #expect(store.destination == home.appending(path: "Downloads"))
    #expect(store.qualityCap == .best)
    #expect(store.output == .videoWithChat)
    #expect(store.chatSize == .medium)
    #expect(store.freeSpaceFloor == Preferences.factoryFreeSpaceFloor)
  }

  @Test func hasSavedDefaultsStartsFalse() throws {
    #expect(store(InMemoryPreferenceStore()).hasSavedDefaults == false)
  }

  // MARK: - Round trips

  @Test func everyFieldSurvivesANewInstanceOverTheSameDefaults() throws {
    let defaults = InMemoryPreferenceStore()
    var writer = store(defaults)
    writer.destination = URL(filePath: "/Volumes/Archive/VODs")
    writer.qualityCap = .p720
    writer.output = .video
    writer.chatSize = .large
    writer.freeSpaceFloor = 12_000_000_000

    let reader = store(defaults)
    #expect(reader.destination == URL(filePath: "/Volumes/Archive/VODs"))
    #expect(reader.qualityCap == .p720)
    #expect(reader.output == .video)
    #expect(reader.chatSize == .large)
    #expect(reader.freeSpaceFloor == 12_000_000_000)
  }

  // MARK: - optionsPanelIsExpanded

  @Test func optionsPanelIsExpandedDefaultsToTrue() throws {
    #expect(store(InMemoryPreferenceStore()).optionsPanelIsExpanded)
  }

  @Test func optionsPanelIsExpandedRoundTrips() throws {
    let defaults = InMemoryPreferenceStore()
    var writer = store(defaults)
    writer.optionsPanelIsExpanded = false
    #expect(store(defaults).optionsPanelIsExpanded == false)
  }

  /// Spec: collapsing the panel is not expressing a preference about
  /// downloads, so it must not set the same flag a real save does — or the
  /// Settings window would start claiming defaults nobody chose.
  @Test func settingOptionsPanelIsExpandedDoesNotSetHasSavedDefaults() throws {
    let defaults = InMemoryPreferenceStore()
    var writer = store(defaults)
    writer.optionsPanelIsExpanded = false
    #expect(store(defaults).hasSavedDefaults == false)
  }

  // MARK: - hasSavedDefaults

  /// Spec §2.4. Saving values identical to the factory ones still counts as
  /// having expressed a preference — comparing against factory would call
  /// that user a first-timer forever.
  @Test func writingAFactoryIdenticalValueStillSetsTheFlag() throws {
    let defaults = InMemoryPreferenceStore()
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
      { (p: inout Preferences) in p.freeSpaceFloor = 1_000_000_000 },
    ] {
      let defaults = InMemoryPreferenceStore()
      var writer = store(defaults)
      mutate(&writer)
      #expect(store(defaults).hasSavedDefaults)
    }
  }

  // MARK: - Restore

  @Test func restoreReturnsEveryFieldAndClearsTheFlag() throws {
    let defaults = InMemoryPreferenceStore()
    var store = store(defaults)
    store.destination = URL(filePath: "/Volumes/Archive")
    store.qualityCap = .p360
    store.output = .video
    store.chatSize = .large
    store.optionsPanelIsExpanded = false
    store.freeSpaceFloor = 5_000_000_000

    store.restoreDefaults()

    #expect(store.destination == home.appending(path: "Downloads"))
    #expect(store.qualityCap == .best)
    #expect(store.output == .videoWithChat)
    #expect(store.chatSize == .medium)
    #expect(store.optionsPanelIsExpanded)
    #expect(store.freeSpaceFloor == Preferences.factoryFreeSpaceFloor)
    #expect(store.hasSavedDefaults == false)
  }

  // MARK: - freeSpaceFloor

  /// The same failure mode `QualityLadderTests.rawValuesArePersistedAndPinned`
  /// pins the quality cap's raw values against: a rename of the stored key or
  /// a change to the factory value's unit must fail a test, not silently
  /// orphan whatever is already on disk.
  @Test func freeSpaceFloorKeyAndFactoryValueArePinned() throws {
    let defaults = InMemoryPreferenceStore()
    defaults.set(Int64(7_000_000_000), forKey: "freeSpaceFloor")
    #expect(store(defaults).freeSpaceFloor == 7_000_000_000)

    // The factory value: the peak `docs/design/disk-preflight.md` §5 prices
    // for a six-hour 1080p60 job with chat (23 + 10 + 15 GB, "about 49 GB"),
    // in bytes. A change here means either the estimator's own worked
    // example changed or someone rounded this to something tidier — the
    // test exists to force that to be a deliberate edit.
    #expect(Preferences.factoryFreeSpaceFloor == 49_000_000_000)
  }

  // MARK: - A destination that no longer resolves

  /// Spec §4.2. Unmounted volume, deleted folder. The disk preflight measures
  /// the volume the destination sits on, so a silent fallback would change
  /// what the estimate means without changing what it says.
  @Test func aMissingDestinationFallsBackAndSaysSo() throws {
    let defaults = InMemoryPreferenceStore()
    var writer = store(defaults)
    writer.destination = URL(filePath: "/Volumes/Unplugged/VODs")

    let reader = store(defaults, directoryExists: { $0.path != "/Volumes/Unplugged/VODs" })
    #expect(reader.destination == home.appending(path: "Downloads"))
    #expect(reader.storedDestinationIsMissing)
  }

  @Test func aPresentDestinationReportsNothingMissing() throws {
    let defaults = InMemoryPreferenceStore()
    var writer = store(defaults)
    writer.destination = URL(filePath: "/Volumes/Archive/VODs")
    #expect(store(defaults).storedDestinationIsMissing == false)
  }

  /// Nothing stored is not the same as something stored and gone.
  @Test func anUnconfiguredStoreReportsNothingMissing() throws {
    #expect(store(InMemoryPreferenceStore(), directoryExists: { _ in false }).storedDestinationIsMissing == false)
  }
}
