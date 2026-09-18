import Foundation
import Testing
import OxbowKit
@testable import Oxbow

/// Exercise completion recording through `JobNotifier.apply`, with an injected store and no
/// notification center. Recording must not depend on notification availability.
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

    // Seed a running baseline before the completion transition; initial snapshots are silent.
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
