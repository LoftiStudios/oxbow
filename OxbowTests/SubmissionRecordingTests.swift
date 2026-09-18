import Foundation
import Testing
import OxbowKit
@testable import Oxbow

@Suite("Submission recording")
@MainActor
struct SubmissionRecordingTests {

  private func temporaryDirectory() -> URL {
    URL.temporaryDirectory.appending(path: "submission-record-\(UUID().uuidString)")
  }

  private var fetched: VideoInfoFetcher.Fetched {
    VideoInfoFetcher.Fetched(
      info: VideoInfo(
        streamer: "WheelyF", login: "wheelyf", title: "day 46",
        createdAt: Date(timeIntervalSince1970: 1_757_000_000),
        duration: .seconds(10203),
        qualities: [StreamQuality(name: "1080p60", resolution: "1920x1080", bitsPerSecond: 6_000_000)],
        thumbnailURLs: [
          URL(string: "https://cdn/a.jpg")!, URL(string: "https://cdn/b.jpg")!,
          URL(string: "https://cdn/c.jpg")!, URL(string: "https://cdn/d.jpg")!,
        ]),
      payload: "{\"data\":{\"video\":{}}}\n{\"moments\":true}\n#EXTM3U\n")
  }

  @Test("a submission records qualities, four frames, the login and the payload")
  func submissionRecords() throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let records = VideoRecordStore(fileURL: directory.appending(path: "videos.json"))
    let payloads = PayloadStore(directory: directory.appending(path: "payloads"))

    VideoRecorder.record(
      fetched, for: "2844787557", helperVersion: "1.56.5",
      records: records, payloads: payloads)

    let library = try records.load()
    #expect(library.videos["2844787557"]?.qualities.first?.name == "1080p60")
    #expect(library.videos["2844787557"]?.thumbnailURLs.count == 4)
    #expect(library.videos["2844787557"]?.login == "wheelyf")
    #expect(library.videos["2844787557"]?.payloadHelperVersion == "1.56.5")
    #expect(payloads.payload(for: "2844787557") == fetched.payload)
  }

  /// Retain moments even though today's parser ignores them.
  @Test("the unparsed parts of the payload survive")
  func unparsedPartsSurvive() throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let records = VideoRecordStore(fileURL: directory.appending(path: "videos.json"))
    let payloads = PayloadStore(directory: directory.appending(path: "payloads"))

    VideoRecorder.record(
      fetched, for: "2844787557", helperVersion: "1.56.5",
      records: records, payloads: payloads)

    #expect(payloads.payload(for: "2844787557")?.contains("moments") == true)
  }

  /// A record write must never be able to fail a download. An unusable id is
  /// the cheapest way to force the payload write to throw.
  @Test("a failed payload write still records the facts")
  func payloadFailureIsNotFatal() throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let records = VideoRecordStore(fileURL: directory.appending(path: "videos.json"))
    let payloads = PayloadStore(directory: directory.appending(path: "payloads"))

    VideoRecorder.record(
      fetched, for: "../escape", helperVersion: "1.56.5",
      records: records, payloads: payloads)

    // The facts still landed; only the payload did not.
    #expect(try records.load().videos["../escape"]?.login == "wheelyf")
    #expect(payloads.payload(for: "../escape") == nil)
  }

  /// Do not retain a raw payload without the helper-version stamp needed to interpret it later.
  @Test("an unknown helper version stores facts but no payload")
  func noVersionMeansNoPayload() throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let records = VideoRecordStore(fileURL: directory.appending(path: "videos.json"))
    let payloads = PayloadStore(directory: directory.appending(path: "payloads"))

    VideoRecorder.record(
      fetched, for: "1", helperVersion: nil, records: records, payloads: payloads)

    #expect(try records.load().videos["1"]?.qualities.count == 1)
    #expect(payloads.payload(for: "1") == nil)
  }

  /// Submission must record queued state so subsequent sweeps cannot offer an in-flight archive
  /// again.
  @Test("a submission leaves the video queued")
  func submissionMarksQueued() throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let records = VideoRecordStore(fileURL: directory.appending(path: "videos.json"))
    let payloads = PayloadStore(directory: directory.appending(path: "payloads"))

    VideoRecorder.record(
      fetched, for: "2844787557", helperVersion: "1.56.5",
      records: records, payloads: payloads)

    let library = try records.load()
    #expect(library.watchStates["2844787557"] == .queued)
    // Queued state suppresses duplicate findings.
    #expect(library.seenIDs(forLogin: "wheelyf") == ["2844787557"])
  }

  // MARK: - The two routes that actually record

  /// Inject disposable stores; hosted tests intentionally leave `QueueHost.videoRecording` nil.
  private func makeRecording(in directory: URL) -> VideoRecording {
    VideoRecording(
      records: VideoRecordStore(fileURL: directory.appending(path: "videos.json")),
      payloads: PayloadStore(directory: directory.appending(path: "payloads")))
  }

  /// Stub clock, preferences, paths, and capacity. Use video-only output to isolate recording
  /// from chat eligibility.
  private func makeModel() -> IntakeModel {
    var preferences = Preferences(
      store: InMemoryPreferenceStore(),
      homeDirectory: URL(filePath: "/Users/t"),
      directoryExists: { _ in true })
    preferences.output = .video

    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!

    let payload = fetched
    return IntakeModel(
      fetchInfo: { _ in payload },
      enqueue: { _, _ in },
      calendar: calendar,
      fileExists: { _ in false },
      volumeSpace: VolumeSpace(
        availableBytes: { _ in 1_000_000_000_000 },
        volumeRoot: { _ in URL(filePath: "/") },
        volumeName: { _ in "Macintosh HD" }),
      preferences: preferences)
  }

  /// Exercise recording through the actual intent submission path.
  @Test("a submission through the intent path lands a record and its payload")
  func theIntentPathRecords() async throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let recording = makeRecording(in: directory)

    _ = try await IntentSubmission.submit(
      link: "https://twitch.tv/videos/2844787557",
      quality: nil, output: nil, chatSize: nil, destination: nil,
      into: makeModel(), recording: recording, helperVersion: "1.56.5")

    let library = try recording.records.load()
    #expect(library.videos["2844787557"]?.login == "wheelyf")
    #expect(library.videos["2844787557"]?.title == "day 46")
    #expect(library.videos["2844787557"]?.payloadHelperVersion == "1.56.5")
    #expect(library.watchStates["2844787557"] == .queued)
    #expect(recording.payloads.payload(for: "2844787557") == fetched.payload)
  }

  /// Exercise the window's `IntakeAdd.perform` route so manually pasted videos also enter the
  /// record.
  @Test("pressing Add on a pasted link lands a record and its payload")
  func theAddDownloadPathRecords() async throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let recording = makeRecording(in: directory)

    let model = makeModel()
    model.linkText = "https://twitch.tv/videos/2844787557"
    await model.load()

    let didAdd = await IntakeAdd.perform(
      model, recording: recording, helperVersion: "1.56.5")

    #expect(didAdd)
    let library = try recording.records.load()
    #expect(library.videos["2844787557"]?.login == "wheelyf")
    #expect(library.videos["2844787557"]?.qualities.first?.name == "1080p60")
    #expect(library.watchStates["2844787557"] == .queued)
    #expect(recording.payloads.payload(for: "2844787557") == fetched.payload)
  }

  /// Metadata lookup alone must leave no record. Keep persistence dependencies outside
  /// `IntakeModel` so abandoned links cannot be recorded on load.
  @Test("a fetch with no Add behind it records nothing")
  func lookingAtALinkRecordsNothing() async throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let recording = makeRecording(in: directory)

    let model = makeModel()
    model.linkText = "https://twitch.tv/videos/2844787557"
    await model.load()

    // The fetch landed — this is a real look at a real video, not a model
    // that failed to do anything.
    #expect(model.lastFetch != nil)
    #expect(try recording.records.load().videos.isEmpty)
    #expect(try recording.records.load().watchStates.isEmpty)
    #expect(recording.payloads.payload(for: "2844787557") == nil)
  }

  /// An uncomposed job must leave no record.
  @Test("an add that fails records nothing")
  func aRefusedAddRecordsNothing() async throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let recording = makeRecording(in: directory)

    let model = makeModel()
    model.linkText = "https://twitch.tv/videos/2844787557"

    let didAdd = await IntakeAdd.perform(
      model, recording: recording, helperVersion: "1.56.5")

    #expect(!didAdd)
    #expect(try recording.records.load().videos.isEmpty)
    // Nor queued state without a backing job.
    #expect(try recording.records.load().watchStates.isEmpty)
  }
}
