import Foundation
import Testing
import OxbowKit
@testable import Oxbow

/// Exercises the path `CompletionRecordingTests` cannot reach: a settling job
/// arriving through `JobNotifier.apply(_:)` and landing in the video record,
/// rather than `VideoRecorder.recordCompletion` being called directly.
///
/// This became constructible only once `videoRecordStore` was made
/// assignable from outside `JobNotifier` (see that property's doc comment) —
/// before that, a test had no way to give the notifier a store over a
/// temporary file rather than the developer's real one.
///
/// **Reachable even with `center` nil**, which it always is under
/// `xcodebuild test` — see `center`'s own doc comment. `apply(_:)` no longer
/// gates the record write on `center`: whether a banner can be posted has no
/// bearing on whether a settled job's outcome gets written down, so the two
/// halves of the method run independently. `docs/design/video-record.md` §7.
@Suite("Job notifier recording")
@MainActor
struct JobNotifierRecordingTests {

  private func temporaryFile() -> URL {
    URL.temporaryDirectory
      .appending(path: "job-notifier-\(UUID().uuidString)")
      .appending(path: "videos.json")
  }

  private func step(_ status: StepStatus, videoID: String, artifact: URL? = nil) -> Step {
    Step(
      id: StepID(rawValue: UUID()),
      kind: .downloadVideo(VideoRequest(
        videoID: videoID, quality: "", destination: URL(filePath: "/out/a.mp4"))),
      status: status,
      artifact: artifact)
  }

  private func job(_ id: JobID, _ steps: [Step], title: String = "Stream") -> Job {
    Job(id: id, created: Date(timeIntervalSince1970: 0), title: title, steps: steps)
  }

  @Test("a job reaching finished records its delivered path and the downloaded state")
  func finishedJobRecordsThroughApply() throws {
    let file = temporaryFile()
    defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
    let store = VideoRecordStore(fileURL: file)

    let notifier = JobNotifier()
    notifier.videoRecordStore = store

    let id = JobID(rawValue: UUID())
    let delivered = URL(filePath: "/Volumes/Helios/day46.mp4")

    // A job absent from the baseline never fires — `NotificationDecision
    // .events(from:to:)` seeds silently on the first snapshot — so this
    // first `apply` call, while the job is still running, is what
    // establishes the baseline the transition below is diffed against.
    notifier.apply([job(id, [step(.running, videoID: "2844787557")])])
    notifier.apply([job(
      id, [step(.done, videoID: "2844787557", artifact: delivered)])])

    let library = try store.load()
    #expect(library.videos["2844787557"]?.deliveredPath == delivered.path)
    #expect(library.watchStates["2844787557"] == .downloaded)
  }

  @Test("a job reaching failed records the failed state")
  func failedJobRecordsThroughApply() throws {
    let file = temporaryFile()
    defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
    let store = VideoRecordStore(fileURL: file)

    let notifier = JobNotifier()
    notifier.videoRecordStore = store

    let id = JobID(rawValue: UUID())
    let failure = StepFailure(kind: .noArtifact, summary: "no artifact")

    notifier.apply([job(id, [step(.running, videoID: "1")])])
    notifier.apply([job(id, [step(.failed(failure), videoID: "1")])])

    let library = try store.load()
    #expect(library.watchStates["1"] == .failed)
  }
}
