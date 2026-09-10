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

  /// The moments line is stored even though nothing parses it. That is the
  /// entire reason the payload is kept whole rather than parsed down.
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

  /// No helper version means no stamp — and an unstamped payload is not
  /// re-parseable later, so it is not written at all rather than written
  /// anonymously.
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

  /// **The write that was missing, and the bug it was one swap away from.**
  /// `WatchState.countsAsSeen` reads `queued` as handled, and it is the whole
  /// seen-set (`docs/design/video-record.md` §3.2). Nothing wrote `queued` at
  /// all for a while, so a submitted-but-unfinished archive read as unseen —
  /// latent only because `WatchPoller.markSubmitted` was still writing the
  /// legacy `Watch.seen` beside it. The moment `seenIDs(forLogin:)` becomes
  /// the answer, an archive whose download is still running gets offered and
  /// downloaded a second time.
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
    // The point of the state, asserted rather than assumed: the archive is
    // handled, so the next sweep must not offer it again.
    #expect(library.seenIDs(forLogin: "wheelyf") == ["2844787557"])
  }

  // MARK: - The two routes that actually record

  /// Temp stores in their own directory, so a suite run touches nothing the
  /// developer owns. `VideoRecording`'s memberwise init is internal and this
  /// suite is `@testable`, which is the whole reason the wired paths can be
  /// driven at all: `QueueHost.videoRecording` is deliberately nil under
  /// `xcodebuild test`, so the only way to watch a submission reach the record
  /// is to hand it a handle of one's own.
  private func makeRecording(in directory: URL) -> VideoRecording {
    VideoRecording(
      records: VideoRecordStore(fileURL: directory.appending(path: "videos.json")),
      payloads: PayloadStore(directory: directory.appending(path: "payloads")))
  }

  /// A model wired to `fetched`, enqueueing into nothing.
  ///
  /// Every collaborator that would otherwise read the machine is stubbed, for
  /// the reasons `IntakeModelTests` gives at each: a pinned calendar so
  /// `OutputNaming` does not date the job in the CI runner's zone, an
  /// in-memory preference store with `directoryExists` stubbed true so the
  /// destination does not fall back to a real `~/Downloads`, and a terabyte
  /// free so no disk warning depends on the volume this runs on.
  ///
  /// `output` is pinned to `.video` so that neither `chatProblem` nor
  /// `compositeProblem` can refuse the submission. What is under test here is
  /// where the record gets written, not which outputs a video supports; those
  /// rules have their own suites.
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

  /// The Shortcuts, Spotlight and watched-channel route. `VideoRecorder` is
  /// covered above in isolation; this is the assertion that a real submission
  /// reaches it, which nothing made before — `QueueHost.videoRecording` being
  /// nil under test meant the wiring itself was only ever read, never run.
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

  /// The hand-pasted route, which is the case the record exists for
  /// (`docs/design/video-record.md` §3.5): grab a channel's video by hand
  /// today, add that channel as a watch later, and the row should already know
  /// you have it. Add Download used to call `IntakeModel.add()` directly and
  /// so recorded nothing at all, and no test noticed because the only covered
  /// route was the intent's.
  ///
  /// Drives `IntakeAdd.perform` — every line of the window's Add button that
  /// is not `isAdding`, `dismiss()` or the defaults checkbox.
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

  /// **The rule the whole arrangement exists to keep**: a link that was
  /// looked at and abandoned leaves nothing behind (§3.5). `load()` runs on
  /// every debounced keystroke, so recording there would file every link
  /// anybody ever pasted into the window.
  ///
  /// This is the automated half of that guarantee. The other half is
  /// structural and stronger: `IntakeModel` references no `VideoRecordStore`,
  /// no `PayloadStore` and no `VideoRecording`, so `load()` has nothing it
  /// could write with. Keep it that way — moving the store onto the model to
  /// make some future call site tidier would delete the guarantee and leave
  /// only this test standing between a paste and a permanent record.
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

  /// A refused enqueue must leave no record either: §3.5 is about videos that
  /// were downloaded, and a job that was never composed is not one. The link
  /// here is never `load()`ed, so there is no resolved quality to compose
  /// from and `add()` refuses.
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
    // Nor a state: a video that was never submitted is not queued, and a
    // `queued` state with no job behind it would mask the archive from the
    // next sweep for good.
    #expect(try recording.records.load().watchStates.isEmpty)
  }
}
