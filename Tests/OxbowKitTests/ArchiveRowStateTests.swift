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

  /// Build steps to derive job status, delivered files, and media identity.
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
    #expect(ArchiveRowState.state(for: archive("1"), jobs: [], recordedPath: nil, expectedPath: nil, file: noFile) == .available)
  }

  /// Live broadcasts must remain distinct from completed downloads offered unattended.
  @Test("a still-recording broadcast is live, not available")
  func recordingIsLive() {
    let state = ArchiveRowState.state(
      for: archive("1", status: .recording), jobs: [], recordedPath: nil, expectedPath: nil, file: noFile)
    #expect(state == .live)
  }

  /// Unknown broadcast status must not appear available when unattended policy refuses it.
  @Test("an unrecognised status is not offered as available")
  func unknownStatusIsNotAvailable() {
    let state = ArchiveRowState.state(
      for: archive("1", status: .other("PENDING_TRANSCODE")), jobs: [], recordedPath: nil, expectedPath: nil, file: noFile)
    #expect(state == .live)
  }

  @Test("a queued job reads as queued and a running one as running")
  func unfinishedJobsShowTheirProgress() {
    #expect(ArchiveRowState.state(
      for: archive("1"), jobs: [job("1", .queued)], recordedPath: nil, expectedPath: nil, file: noFile) == .queued)
    #expect(ArchiveRowState.state(
      for: archive("1"), jobs: [job("1", .running)], recordedPath: nil, expectedPath: nil, file: noFile) == .running)
  }

  @Test("a finished job whose file is there is downloaded")
  func doneWithFileIsDownloaded() {
    let path = URL(filePath: "/Users/x/Downloads/a.mp4")
    let state = ArchiveRowState.state(
      for: archive("1"), jobs: [job("1", .done, files: [path])],
      recordedPath: nil, expectedPath: nil, file: { _ in .present(path) })
    #expect(state == .downloaded(path))
  }

  /// Deleted downloads become actionable again.
  @Test("a finished job whose file is gone is missing, not downloaded")
  func doneWithoutFileIsMissing() {
    let state = ArchiveRowState.state(
      for: archive("1"),
      jobs: [job("1", .done, files: [URL(filePath: "/Users/x/Downloads/a.mp4")])],
      recordedPath: nil, expectedPath: nil, file: { _ in .absent })
    #expect(state == .missing)
  }

  /// Unreachable volume is distinct from a deleted file.
  @Test("an unreachable volume is unverifiable, never missing")
  func unreachableVolumeIsUnverifiable() {
    let state = ArchiveRowState.state(
      for: archive("1"),
      jobs: [job("1", .done, files: [URL(filePath: "/Volumes/Helios/a.mp4")])],
      recordedPath: nil, expectedPath: nil, file: { _ in .unknown(volumeName: "Helios") })
    #expect(state == .unverifiable(volumeName: "Helios"))
  }

  @Test("a failed job reads as failed")
  func failedJobIsFailed() {
    #expect(ArchiveRowState.state(
      for: archive("1"), jobs: [job("1", .failed)], recordedPath: nil, expectedPath: nil, file: noFile) == .failed)
  }

  /// Cancellation returns the row to manual availability.
  @Test("a cancelled job leaves the archive available")
  func cancelledJobIsAvailableAgain() {
    #expect(ArchiveRowState.state(
      for: archive("1"), jobs: [job("1", .cancelled)], recordedPath: nil, expectedPath: nil, file: noFile) == .available)
  }

  @Test("jobs for other archives are ignored")
  func otherJobsDoNotLeak() {
    #expect(ArchiveRowState.state(
      for: archive("1"), jobs: [job("2", .running)], recordedPath: nil, expectedPath: nil, file: noFile) == .available)
  }

  /// An unfinished retry outranks a previous completed job, regardless of array order.
  @Test("an unfinished job outranks a finished one for the same archive")
  func unfinishedOutranksFinished() {
    let path = URL(filePath: "/Users/x/Downloads/a.mp4")
    let jobs = [job("1", .done, files: [path]), job("1", .running)]
    #expect(ArchiveRowState.state(
      for: archive("1"), jobs: jobs, recordedPath: nil, expectedPath: nil, file: { _ in .present(path) }) == .running)
    #expect(ArchiveRowState.state(
      for: archive("1"), jobs: jobs.reversed(), recordedPath: nil, expectedPath: nil, file: { _ in .present(path) }) == .running)
  }

  /// An existing delivered file outranks an older failure for the same archive.
  @Test("a done job with its file present outranks a coexisting failed job")
  func doneOutranksFailed() {
    let path = URL(filePath: "/Users/x/Downloads/a.mp4")
    let jobs = [job("1", .failed), job("1", .done, files: [path])]
    #expect(ArchiveRowState.state(
      for: archive("1"), jobs: jobs, recordedPath: nil, expectedPath: nil, file: { _ in .present(path) }) == .downloaded(path))
    #expect(ArchiveRowState.state(
      for: archive("1"), jobs: jobs.reversed(), recordedPath: nil, expectedPath: nil, file: { _ in .present(path) }) == .downloaded(path))
  }

  /// Done without a delivered artifact must not claim a file.
  @Test("a finished job with no delivered file is missing, not a crash")
  func doneWithNoDeliveredFileIsMissing() {
    #expect(ArchiveRowState.state(
      for: archive("1"), jobs: [job("1", .done, files: [])], recordedPath: nil, expectedPath: nil, file: noFile) == .missing)
  }

  /// Pin every fetchable state because it controls both Add and Ignore. Missing files and live
  /// broadcasts remain actionable manually.
  @Test("every state says whether a person may still choose to fetch it")
  func fetchableStates() {
    #expect(ArchiveRowState.available.isFetchable)
    #expect(ArchiveRowState.live.isFetchable)
    #expect(ArchiveRowState.missing.isFetchable)
    #expect(ArchiveRowState.failed.isFetchable)

    #expect(!ArchiveRowState.queued.isFetchable)
    #expect(!ArchiveRowState.running.isFetchable)
    #expect(!ArchiveRowState.downloaded(URL(filePath: "/a.mp4")).isFetchable)
    #expect(!ArchiveRowState.unverifiable(volumeName: "Helios").isFetchable)
  }

  /// Recorded delivery must survive removal of the completed queue job.
  @Test("a recorded path answers downloaded once the job is gone")
  func recordedPathSurvivesTheJob() {
    let path = URL(filePath: "/Volumes/Storage/wheelyf/day46.mp4")
    let state = ArchiveRowState.state(
      for: archive("1"), jobs: [],
      recordedPath: "/Volumes/Storage/wheelyf/day46.mp4",
      expectedPath: nil,
      file: { _ in .present(path) })
    #expect(state == .downloaded(path))
  }

  /// The volume is asked about before the file, for the reason §4.1 gives:
  /// "could not ask" is not "the answer is no".
  @Test("a recorded path on an unreachable volume is unverifiable, not missing")
  func recordedPathOnAnUnreachableVolume() {
    let state = ArchiveRowState.state(
      for: archive("1"), jobs: [],
      recordedPath: "/Volumes/Storage/a.mp4",
      expectedPath: nil,
      file: { _ in .unknown(volumeName: "Storage") })
    #expect(state == .unverifiable(volumeName: "Storage"))
  }

  /// Missing recorded files must not claim availability on disk.
  @Test("a recorded path whose file was deleted returns to actionable")
  func deletedRecordedFileReturnsToActionable() {
    let state = ArchiveRowState.state(
      for: archive("1"), jobs: [],
      recordedPath: "/Volumes/Storage/gone.mp4",
      expectedPath: nil,
      file: { _ in .absent })
    #expect(state == .available)
  }

  /// A missing recorded file must not hide a newer retry failure.
  @Test("a stale recorded path never masks a failed retry")
  func staleRecordedPathDoesNotMaskAFailure() {
    let state = ArchiveRowState.state(
      for: archive("1"), jobs: [job("1", .failed)],
      recordedPath: "/Volumes/Storage/gone.mp4",
      expectedPath: nil,
      file: { _ in .absent })
    #expect(state == .failed)
  }

  /// A job in hand names the file *this* run produced; the record names
  /// whatever an earlier one did. The job wins.
  @Test("a finished job outranks the recorded path")
  func finishedJobOutranksTheRecord() {
    let fromJob = URL(filePath: "/out/from-job.mp4")
    let state = ArchiveRowState.state(
      for: archive("1"), jobs: [job("1", .done, files: [fromJob])],
      recordedPath: "/out/from-record.mp4",
      expectedPath: nil,
      file: { url in .present(url) })
    #expect(state == .downloaded(fromJob))
  }


  /// Unreachable recorded files still count as held, preserving offline library rows.
  @Test("only the two states with something on disk hold a file")
  func holdsAFile() {
    #expect(ArchiveRowState.downloaded(URL(filePath: "/a.mp4")).holdsAFile)
    #expect(ArchiveRowState.unverifiable(volumeName: "Storage").holdsAFile)
    for state: ArchiveRowState in [.available, .live, .queued, .running, .missing, .failed] {
      #expect(!state.holdsAFile, "\(state) has nothing on disk")
    }
  }


  /// Recognize older downloads by their derived destination when no record exists.
  @Test("a file where the download would have gone reads as downloaded")
  func expectedPathIsRecognised() {
    let path = URL(filePath: "/Volumes/Storage/WheelyF - 2026-08-12 - day 46.mp4")
    let state = ArchiveRowState.state(
      for: archive("1"), jobs: [], recordedPath: nil,
      expectedPath: "/Volumes/Storage/WheelyF - 2026-08-12 - day 46.mp4",
      file: { _ in .present(path) })
    #expect(state == .downloaded(path))
  }

  /// An unreachable recorded path preserves a known claim; an unreachable derived path proves
  /// nothing about whether a download ever happened.
  @Test("an expected path on an unreachable volume claims nothing")
  func expectedPathDoesNotClaimAnUnreachableVolume() {
    let state = ArchiveRowState.state(
      for: archive("1"), jobs: [], recordedPath: nil,
      expectedPath: "/Volumes/Storage/a.mp4",
      file: { _ in .unknown(volumeName: "Storage") })
    #expect(state == .available, "a guess must not survive an unanswerable question")
  }

  /// The ordinary case: 150 of 160 recorded videos are not downloaded, and
  /// each must stay offerable.
  @Test("an expected path with no file leaves the archive actionable")
  func expectedPathWithNoFileIsActionable() {
    let state = ArchiveRowState.state(
      for: archive("1"), jobs: [], recordedPath: nil,
      expectedPath: "/Volumes/Storage/absent.mp4",
      file: { _ in .absent })
    #expect(state == .available)
  }

  /// An existing derived file wins even without a surviving queue job.
  @Test("a file on disk outranks a failed job")
  func fileOutranksAFailedJob() {
    let path = URL(filePath: "/Volumes/Storage/a.mp4")
    let state = ArchiveRowState.state(
      for: archive("1"), jobs: [job("1", .failed)], recordedPath: nil,
      expectedPath: "/Volumes/Storage/a.mp4",
      file: { _ in .present(path) })
    #expect(state == .downloaded(path))
  }

  /// A recorded path names the file this app actually delivered; an expected
  /// path is where it would have gone. The record wins.
  @Test("a recorded path outranks an expected one")
  func recordedPathOutranksExpected() {
    let recorded = URL(filePath: "/Volumes/Storage/recorded.mp4")
    let state = ArchiveRowState.state(
      for: archive("1"), jobs: [], recordedPath: "/Volumes/Storage/recorded.mp4",
      expectedPath: "/Volumes/Storage/expected.mp4",
      file: { url in .present(url) })
    #expect(state == .downloaded(recorded))
  }


  /// Unverifiable files are held but cannot be opened; gestures must check openability.
  @Test("only a file that is actually there can be opened")
  func openableFile() {
    let url = URL(filePath: "/Volumes/Storage/a.mp4")
    #expect(ArchiveRowState.downloaded(url).openableFile == url)
    #expect(ArchiveRowState.unverifiable(volumeName: "Storage").openableFile == nil,
            "an unplugged disk has nothing to hand a player")
    for state: ArchiveRowState in [.available, .live, .queued, .running, .missing, .failed] {
      #expect(state.openableFile == nil, "\(state) has no file")
    }
  }

}

/// `ArchiveRowState.FileAnswer.resolve` is the live probe's pure core: no
/// disk, just the two facts a real filesystem check would supply.
@Suite("Live file answer resolution")
struct FileAnswerResolutionTests {

  @Test("a present file answers present")
  func filePresent() {
    let url = URL(filePath: "/Volumes/Helios/a.mp4")
    let answer = ArchiveRowState.FileAnswer.resolve(
      url, fileExists: { _ in true }, folderExists: { _ in true })
    #expect(answer == .present(url))
  }

  /// An accessible parent distinguishes an absent file from an unreachable volume.
  @Test("a gone file with its folder present is absent")
  func fileGoneFolderPresent() {
    let answer = ArchiveRowState.FileAnswer.resolve(
      URL(filePath: "/Volumes/Helios/a.mp4"),
      fileExists: { _ in false }, folderExists: { _ in true })
    #expect(answer == .absent)
  }

  /// Name an unreachable volume from its path because it cannot be queried.
  @Test("a gone folder under /Volumes is unknown, named from the path")
  func folderGoneUnderVolumes() {
    let answer = ArchiveRowState.FileAnswer.resolve(
      URL(filePath: "/Volumes/Helios/a.mp4"),
      fileExists: { _ in false }, folderExists: { _ in false })
    #expect(answer == .unknown(volumeName: "Helios"))
  }

  /// Outside `/Volumes` there is no disk name to read off the path, so the
  /// missing folder's own name is the closest honest answer.
  @Test("a gone folder outside /Volumes is unknown, named from the folder")
  func folderGoneOutsideVolumes() {
    let answer = ArchiveRowState.FileAnswer.resolve(
      URL(filePath: "/Users/x/Downloads/a.mp4"),
      fileExists: { _ in false }, folderExists: { _ in false })
    #expect(answer == .unknown(volumeName: "Downloads"))
  }
}
