import Foundation
import Testing
@testable import OxbowKit

@Suite("Archive row state")
struct ArchiveRowStateTests {

  private func archive(
    _ id: String, status: ChannelArchive.Status = .recorded
  ) -> ChannelArchive {
    ChannelArchive(id: id, title: "t", duration: .seconds(60),
                   publishedAt: Date(timeIntervalSince1970: 0), status: status,
                   thumbnailURL: nil)
  }

  /// Always answers `absent`, for the cases where no file is involved.
  private let noFile: (URL) -> ArchiveRowState.FileAnswer = { _ in .absent }

  /// `Job.status`, `deliveredFiles` and `mediaIdentifier` are all derived
  /// from `steps` (see `Job.swift`), so a fixture builds the step that
  /// produces the wanted values rather than setting properties directly.
  private func step(
    _ status: StepStatus, videoID: String, artifact: URL? = nil
  ) -> Step {
    Step(
      id: StepID(rawValue: UUID()),
      kind: .downloadVideo(VideoRequest(
        videoID: videoID, quality: "", destination: URL(filePath: "/out/a.mp4"))),
      status: status,
      artifact: artifact)
  }

  private func job(
    _ mediaIdentifier: String, _ status: JobStatus, files: [URL] = []
  ) -> Job {
    let stepStatus: StepStatus = switch status {
    case .queued: .queued
    case .running: .running
    case .done: .done
    case .failed: .failed(StepFailure(kind: .noArtifact, summary: "no artifact"))
    case .cancelled: .cancelled
    }
    return Job(
      id: JobID(rawValue: UUID()), created: Date(timeIntervalSince1970: 0),
      title: "Stream",
      steps: [step(stepStatus, videoID: mediaIdentifier, artifact: files.first)])
  }

  @Test("an archive with no job is available to fetch")
  func noJobIsAvailable() {
    #expect(ArchiveRowState.state(for: archive("1"), jobs: [], file: noFile) == .available)
  }

  /// §5.2 of the watching design: a broadcast still recording is skipped by
  /// the unattended path and must not read as an ordinary row a person is
  /// invited to grab half of.
  @Test("a still-recording broadcast is live, not available")
  func recordingIsLive() {
    let state = ArchiveRowState.state(
      for: archive("1", status: .recording), jobs: [], file: noFile)
    #expect(state == .live)
  }

  @Test("a queued job reads as queued and a running one as running")
  func unfinishedJobsShowTheirProgress() {
    #expect(ArchiveRowState.state(
      for: archive("1"), jobs: [job("1", .queued)], file: noFile) == .queued)
    #expect(ArchiveRowState.state(
      for: archive("1"), jobs: [job("1", .running)], file: noFile) == .running)
  }

  @Test("a finished job whose file is there is downloaded")
  func doneWithFileIsDownloaded() {
    let path = URL(filePath: "/Users/x/Downloads/a.mp4")
    let state = ArchiveRowState.state(
      for: archive("1"), jobs: [job("1", .done, files: [path])],
      file: { _ in .present(path) })
    #expect(state == .downloaded(path))
  }

  /// §4: deleting a download un-does it. The row goes back to something you
  /// can fetch again rather than claiming you have it.
  @Test("a finished job whose file is gone is missing, not downloaded")
  func doneWithoutFileIsMissing() {
    let state = ArchiveRowState.state(
      for: archive("1"),
      jobs: [job("1", .done, files: [URL(filePath: "/Users/x/Downloads/a.mp4")])],
      file: { _ in .absent })
    #expect(state == .missing)
  }

  /// §4.1, and the whole reason the answer is three-valued. An unplugged
  /// drive must not read as a deleted file, or a library vanishes from the
  /// view the moment it is unmounted.
  @Test("an unreachable volume is unverifiable, never missing")
  func unreachableVolumeIsUnverifiable() {
    let state = ArchiveRowState.state(
      for: archive("1"),
      jobs: [job("1", .done, files: [URL(filePath: "/Volumes/Helios/a.mp4")])],
      file: { _ in .unknown(volumeName: "Helios") })
    #expect(state == .unverifiable(volumeName: "Helios"))
  }

  @Test("a failed job reads as failed")
  func failedJobIsFailed() {
    #expect(ArchiveRowState.state(
      for: archive("1"), jobs: [job("1", .failed)], file: noFile) == .failed)
  }

  /// A cancellation is a person saying no, not the app having tried and
  /// lost — the same rule `AutoDownloadObserver` already keeps. The row
  /// returns to being something they can pick up again.
  @Test("a cancelled job leaves the archive available")
  func cancelledJobIsAvailableAgain() {
    #expect(ArchiveRowState.state(
      for: archive("1"), jobs: [job("1", .cancelled)], file: noFile) == .available)
  }

  @Test("jobs for other archives are ignored")
  func otherJobsDoNotLeak() {
    #expect(ArchiveRowState.state(
      for: archive("1"), jobs: [job("2", .running)], file: noFile) == .available)
  }

  /// Re-downloading after a delete leaves two jobs for one archive. The
  /// unfinished one is what the person is waiting on, so it wins over the
  /// finished one regardless of array order.
  @Test("an unfinished job outranks a finished one for the same archive")
  func unfinishedOutranksFinished() {
    let path = URL(filePath: "/Users/x/Downloads/a.mp4")
    let jobs = [job("1", .done, files: [path]), job("1", .running)]
    #expect(ArchiveRowState.state(
      for: archive("1"), jobs: jobs, file: { _ in .present(path) }) == .running)
    #expect(ArchiveRowState.state(
      for: archive("1"), jobs: jobs.reversed(), file: { _ in .present(path) }) == .running)
  }

  /// A finished job that delivered nothing cannot claim a file. Pinned
  /// because `deliveredFiles` is derived from a step's output and an
  /// interrupted run can leave it empty.
  @Test("a finished job with no delivered file is missing, not a crash")
  func doneWithNoDeliveredFileIsMissing() {
    #expect(ArchiveRowState.state(
      for: archive("1"), jobs: [job("1", .done, files: [])], file: noFile) == .missing)
  }
}
