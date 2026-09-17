import Foundation
import Testing
import OxbowKit
@testable import Oxbow

@MainActor
@Suite("Download Twitch Video intent")
struct DownloadTwitchVideoIntentTests {

  /// Omitted intent arguments resolve from saved preferences.
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

  /// Apply overrides before `load()`, which resolves quality using both cap and output mode.
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

  /// A synthetic 284x1 rendition separates the filters: quality selection can read its short
  /// side, but composite geometry rounds its height to zero. Applying video-only output before
  /// load selects it under p480; applying it too late leaves the composite filter and selects
  /// 1080p60 instead.
  @Test func anOutputOverrideIsAppliedBeforeMetadataResolves() async throws {
    let model = makeModel(
      preferences: store { $0.qualityCap = .p480 },
      qualities: [
        StreamQuality(name: "1080p60", resolution: "1920x1080", bitsPerSecond: 8_000_000),
        StreamQuality(name: "160p30", resolution: "284x1", bitsPerSecond: 200_000),
      ])

    _ = try await IntentSubmission.submit(
      link: "https://twitch.tv/videos/123",
      quality: nil, output: .video, chatSize: nil, destination: nil,
      into: model)

    #expect(model.quality == "160p30")
  }

  /// Leave the store untouched during setup. Even writing factory-identical values sets
  /// `hasSavedDefaults`, masking whether submission wrote preferences.
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

  /// Assert the specific failure and zero fetches. A missing early guard still throws a
  /// different `Failure`, and downstream guards also avoid fetching, so neither assertion alone
  /// is sufficient.
  @Test func anUnrecognizedLinkIsRefusedBeforeAnyFetch() async {
    let fetchCounter = FetchCounter()
    let model = makeModel(preferences: store(), fetchCounter: fetchCounter)

    await #expect(throws: IntentSubmission.Failure.unrecognizedLink) {
      _ = try await IntentSubmission.submit(
        link: "https://example.com/not-twitch",
        quality: nil, output: nil, chatSize: nil, destination: nil,
        into: model)
    }

    #expect(fetchCounter.count == 0)
  }

  /// Pins literal error rewriting from intake's “Video” control to the intent's “Video only”
  /// output. A copy change must not silently leave instructions for a nonexistent control.
  @Test func aChatProblemIsRewordedForTheIntentsSurface() async {
    let model = makeModel(preferences: store(), hasDownloadableChat: false)

    do {
      _ = try await IntentSubmission.submit(
        link: "https://twitch.tv/videos/123",
        quality: nil, output: nil, chatSize: nil, destination: nil,
        into: model)
      Issue.record("expected a chat-problem refusal")
    } catch let error as IntentSubmission.Failure {
      guard case .refused(let message) = error else {
        Issue.record("expected .refused, got \(error)")
        return
      }
      #expect(message.contains("Set Output to \"Video only\""))
      #expect(!message.contains("Choose \"Video\""))
    } catch {
      Issue.record("expected IntentSubmission.Failure, got \(error)")
    }
  }

  @Test func aSuccessfulSubmissionReturnsTheJobName() async throws {
    let model = makeModel(preferences: store())

    let outcome = try await IntentSubmission.submit(
      link: "https://twitch.tv/videos/123",
      quality: nil, output: nil, chatSize: nil, destination: nil,
      into: model)

    #expect(outcome == .queued(model.outputBaseName))
    #expect(outcome.value.isEmpty == false)
  }

  // MARK: - The duplicate guard

  /// Repeated Spotlight submissions must not create identical long downloads.
  @Test func aSecondSubmissionOfAQueuedVideoQueuesNothing() async throws {
    let counter = FetchCounter()
    let model = makeModel(preferences: store(), fetchCounter: counter)

    let outcome = try await IntentSubmission.submit(
      link: "https://twitch.tv/videos/2820754270",
      quality: nil, output: nil, chatSize: nil, destination: nil,
      existingJobs: [queuedJob(videoID: "2820754270", title: "LeighXP - going deeper")],
      into: model)

    #expect(outcome == .alreadyQueued("LeighXP - going deeper"))
    // Refused before the fetch: a duplicate should not cost a network round
    // trip either.
    #expect(counter.count == 0)
  }

  @Test func theGuardMatchesOnTheIdentifierNotTheTypedText() async throws {
    let model = makeModel(preferences: store())

    let outcome = try await IntentSubmission.submit(
      link: "2820754270",
      quality: nil, output: nil, chatSize: nil, destination: nil,
      existingJobs: [queuedJob(videoID: "2820754270", title: "Same stream")],
      into: model)

    #expect(outcome == .alreadyQueued("Same stream"))
  }

  /// Failed/cancelled jobs must allow another attempt from an intent with no visible retry UI.
  @Test func aFailedJobDoesNotBlockAFreshAttempt() async throws {
    let model = makeModel(preferences: store())

    let outcome = try await IntentSubmission.submit(
      link: "https://twitch.tv/videos/2820754270",
      quality: nil, output: nil, chatSize: nil, destination: nil,
      existingJobs: [failedJob(videoID: "2820754270")],
      into: model)

    #expect(outcome == .queued(model.outputBaseName))
  }

  @Test func aDifferentVideoIsNotADuplicate() async throws {
    let model = makeModel(preferences: store())

    let outcome = try await IntentSubmission.submit(
      link: "https://twitch.tv/videos/999",
      quality: nil, output: nil, chatSize: nil, destination: nil,
      existingJobs: [queuedJob(videoID: "2820754270", title: "Another stream")],
      into: model)

    #expect(outcome == .queued(model.outputBaseName))
  }

  // MARK: - What the user is told

  /// Duplicates still return the filename for subsequent Shortcuts actions.
  @Test func bothOutcomesCarryTheBaseNameAsTheirValue() {
    #expect(IntentSubmission.Outcome.queued("A Stream").value == "A Stream")
    #expect(IntentSubmission.Outcome.alreadyQueued("A Stream").value == "A Stream")
  }

  /// New and duplicate submissions need distinct confirmation messages.
  @Test func theTwoOutcomesReadDifferently() {
    let queued = IntentSubmission.Outcome.queued("A Stream")
    let duplicate = IntentSubmission.Outcome.alreadyQueued("A Stream")

    #expect(queued.dialog != duplicate.dialog)
    #expect(queued.notificationTitle != duplicate.notificationTitle)
    #expect(queued.dialog.contains("A Stream"))
    #expect(duplicate.dialog.contains("A Stream"))
    #expect(duplicate.dialog.lowercased().contains("already"))
  }

  // MARK: - Fixtures

  /// A queued VOD job, as the engine would hold one.
  private func queuedJob(videoID: String, title: String) -> Job {
    Job(
      id: JobID(rawValue: UUID()), created: Date(), title: title,
      steps: [Step(
        id: StepID(rawValue: UUID()),
        kind: .downloadVideo(VideoRequest(videoID: videoID, quality: "")))])
  }

  /// The same job after its download failed — `Job.status` derives `.failed`
  /// from the step, so this is a real failed job rather than a flag.
  private func failedJob(videoID: String) -> Job {
    Job(
      id: JobID(rawValue: UUID()), created: Date(), title: "Gave up",
      steps: [Step(
        id: StepID(rawValue: UUID()),
        kind: .downloadVideo(VideoRequest(videoID: videoID, quality: "")),
        status: .failed(StepFailure(kind: .interrupted, summary: "The app quit.")))])
  }

  /// Counts metadata fetches to verify early refusals avoid network work.
  private final class FetchCounter {
    private(set) var count = 0
    func record() { count += 1 }
  }

  /// Stubbed metadata and disk capacity keep intent tests independent of network and local
  /// storage.
  private func makeModel(
    preferences: Preferences,
    fetchCounter: FetchCounter? = nil,
    hasDownloadableChat: Bool = true,
    qualities: [StreamQuality] = [
      StreamQuality(name: "1080p60", resolution: "1920x1080", bitsPerSecond: 8_000_000),
      StreamQuality(name: "720p60", resolution: "1280x720", bitsPerSecond: 3_000_000),
      StreamQuality(name: "480p30", resolution: "852x480", bitsPerSecond: 1_500_000),
    ]
  ) -> IntakeModel {
    IntakeModel(
      fetchInfo: { _ in
        fetchCounter?.record()
        return VideoInfoFetcher.Fetched(
          info: VideoInfo(
            streamer: "streamer",
            title: "A Stream",
            createdAt: Date(timeIntervalSince1970: 1_755_000_000),
            duration: .seconds(3600),
            qualities: qualities,
            hasDownloadableChat: hasDownloadableChat),
          payload: "")
      },
      enqueue: { _, _ in },
      calendar: Self.pacific,
      fileExists: { _ in false },
      volumeSpace: VolumeSpace(
        availableBytes: { _ in 1_000_000_000_000 },
        volumeRoot: { _ in URL(filePath: "/") },
        volumeName: { _ in "Macintosh HD" }),
      preferences: preferences)
  }

  /// Pin the calendar so names cannot vary with the test machine's time zone.
  private static var pacific: Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
    return calendar
  }

  /// In-memory preferences with an injected home and existence check; fictional destinations
  /// must not fall back based on the real filesystem.
  private func store(_ configure: (inout Preferences) -> Void = { _ in }) -> Preferences {
    var preferences = Preferences(
      store: InMemoryPreferenceStore(),
      homeDirectory: URL(filePath: "/Users/t"),
      directoryExists: { _ in true })
    configure(&preferences)
    return preferences
  }
}
