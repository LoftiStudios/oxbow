import Foundation
import Testing
import OxbowKit
@testable import Oxbow

@MainActor
@Suite("Download Twitch Video intent")
struct DownloadTwitchVideoIntentTests {

  /// Omitted parameters mean "whatever the Settings window says", never a
  /// factory value. An action and the app disagreeing about what the user
  /// asked for is worse here than anywhere, because the action is the one
  /// nobody is watching.
  @Test func omittedParametersTakeTheStoredPreferences() async throws {
    let model = makeModel(preferences: store {
      $0.qualityCap = .p720
      $0.output = .video
      $0.chatSize = .large
      $0.destination = URL(filePath: "/Volumes/Archive")
    })

    _ = try await IntentSubmission.submit(
      link: "https://twitch.tv/videos/123",
      quality: nil, output: nil, chatSize: nil, destination: nil,
      into: model)

    #expect(model.qualityCap == .p720)
    #expect(model.output == .video)
    #expect(model.chatSize == .large)
    #expect(model.folder == URL(filePath: "/Volumes/Archive"))
  }

  /// **The ordering constraint.** `load()` reads `output` to decide whether
  /// resolution must skip a rendition a composite cannot use (settings.md
  /// §3.4) and reads `qualityCap` to pick the rendition at all. Overrides
  /// applied afterwards resolve the quality against the wrong policy and
  /// leave `quality` naming a rendition the override never asked for.
  @Test func overridesAreAppliedBeforeMetadataResolves() async throws {
    let model = makeModel(preferences: store { $0.qualityCap = .best })

    _ = try await IntentSubmission.submit(
      link: "https://twitch.tv/videos/123",
      quality: .p480, output: nil, chatSize: nil, destination: nil,
      into: model)

    // The stub video offers 1080p60, 720p60 and 480p30. Resolving `.best`
    // would have picked 1080p60; the override must have been in place first.
    #expect(model.quality == "480p30")
  }

  /// An override is a decision about this run, not a standing preference.
  /// `settings.md` §2.2 refuses last-used-wins for the window; an automation
  /// silently rewriting the user's defaults is a worse version of it.
  /// **Untouched `store()`, deliberately, rather than `store { $0.qualityCap
  /// = .best }`.** The brief's own fixture set `.best` explicitly — but
  /// `.best` is already `QualityCap`'s factory value, and setting it through
  /// `Preferences`' public setter still calls `recordSave()`
  /// (`PreferencesTests.writingAFactoryIdenticalValueStillSetsTheFlag` pins
  /// exactly this: a factory-identical write still flips the flag). Doing
  /// that in fixture *setup* would flip `hasSavedDefaults` to `true` before
  /// `submit` ever runs, which makes the final assertion below pass or fail
  /// for a reason that has nothing to do with `submit` — it would read
  /// `true` even if `submit` never touched the store at all. Leaving every
  /// field at its factory value (by never writing to `preferences` at all)
  /// is what makes `hasSavedDefaults == false` afterwards mean what it says:
  /// nothing written, by anyone, at any point in this test.
  @Test func noOverrideIsEverWrittenBackToTheStore() async throws {
    let preferences = store()
    let model = makeModel(preferences: preferences)

    _ = try await IntentSubmission.submit(
      link: "https://twitch.tv/videos/123",
      quality: .p360, output: .video, chatSize: .small, destination: nil,
      into: model)

    #expect(preferences.qualityCap == .best)
    #expect(preferences.output == .videoWithChat)
    #expect(preferences.chatSize == .medium)
    #expect(preferences.hasSavedDefaults == false)
  }

  @Test func anUnrecognizedLinkIsRefusedBeforeAnyFetch() async {
    let model = makeModel(preferences: store())

    await #expect(throws: IntentSubmission.Failure.self) {
      _ = try await IntentSubmission.submit(
        link: "https://example.com/not-twitch",
        quality: nil, output: nil, chatSize: nil, destination: nil,
        into: model)
    }
  }

  @Test func aSuccessfulSubmissionReturnsTheJobName() async throws {
    let model = makeModel(preferences: store())

    let name = try await IntentSubmission.submit(
      link: "https://twitch.tv/videos/123",
      quality: nil, output: nil, chatSize: nil, destination: nil,
      into: model)

    #expect(name == model.outputBaseName)
    #expect(name.isEmpty == false)
  }

  // MARK: - Fixtures

  /// A model wired to the stub video every test above resolves against.
  ///
  /// Mirrors `IntakeModelTests.makeModel`/`.info` rather than inventing a
  /// second shape for the same fixture: `VideoInfo`'s and `StreamQuality`'s
  /// real initializers (both `public init` in
  /// `Sources/OxbowKit/Model/VideoInfo.swift`) require `bitsPerSecond` on
  /// every `StreamQuality`, which an earlier draft of this fixture omitted.
  /// `volumeSpace` is stubbed with a terabyte free for the same reason
  /// `IntakeModelTests` stubs it everywhere: `IntakeModel`'s designated init
  /// defaults it to `.live`, and a unit test has no business reading the
  /// real disk.
  private func makeModel(preferences: Preferences) -> IntakeModel {
    IntakeModel(
      fetchInfo: { _ in
        VideoInfo(
          streamer: "streamer",
          title: "A Stream",
          createdAt: Date(timeIntervalSince1970: 1_755_000_000),
          duration: .seconds(3600),
          qualities: [
            StreamQuality(name: "1080p60", resolution: "1920x1080", bitsPerSecond: 8_000_000),
            StreamQuality(name: "720p60", resolution: "1280x720", bitsPerSecond: 3_000_000),
            StreamQuality(name: "480p30", resolution: "852x480", bitsPerSecond: 1_500_000),
          ],
          hasDownloadableChat: true)
      },
      enqueue: { _, _ in },
      fileExists: { _ in false },
      volumeSpace: VolumeSpace(
        availableBytes: { _ in 1_000_000_000_000 },
        volumeRoot: { _ in URL(filePath: "/") },
        volumeName: { _ in "Macintosh HD" }),
      preferences: preferences)
  }

  /// A `Preferences` over its own in-memory store, with a fixed fictional
  /// home directory and `directoryExists` stubbed true — copied from
  /// `IntakeModelTests.store`. Without the stub, `/Volumes/Archive` in
  /// `omittedParametersTakeTheStoredPreferences` would read back through
  /// `Preferences.destination`'s real `FileManager` check, find nothing
  /// there, and silently fall back to `~/Downloads` — failing that test for
  /// a reason that has nothing to do with what it verifies.
  private func store(_ configure: (inout Preferences) -> Void = { _ in }) -> Preferences {
    var preferences = Preferences(
      store: InMemoryPreferenceStore(),
      homeDirectory: URL(filePath: "/Users/t"),
      directoryExists: { _ in true })
    configure(&preferences)
    return preferences
  }
}
