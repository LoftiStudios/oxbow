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
    #expect(ArchiveRowState.state(for: archive("1"), jobs: [], recordedPath: nil, file: noFile) == .available)
  }

  /// §5.2 of the watching design: a broadcast still recording is skipped by
  /// the unattended path and must not read as an ordinary row a person is
  /// invited to grab half of.
  @Test("a still-recording broadcast is live, not available")
  func recordingIsLive() {
    let state = ArchiveRowState.state(
      for: archive("1", status: .recording), jobs: [], recordedPath: nil, file: noFile)
    #expect(state == .live)
  }

  /// A status this app has never seen decodes to `.other` and
  /// `ChannelArchive.isDownloadable` refuses to call it safe, so
  /// `AutoDownloadPolicy` will not queue it. Reading it as `.available` would
  /// put a prominent Add on an archive the app's own policy layer declines —
  /// two surfaces disagreeing about one video.
  @Test("an unrecognised status is not offered as available")
  func unknownStatusIsNotAvailable() {
    let state = ArchiveRowState.state(
      for: archive("1", status: .other("PENDING_TRANSCODE")), jobs: [], recordedPath: nil, file: noFile)
    #expect(state == .live)
  }

  @Test("a queued job reads as queued and a running one as running")
  func unfinishedJobsShowTheirProgress() {
    #expect(ArchiveRowState.state(
      for: archive("1"), jobs: [job("1", .queued)], recordedPath: nil, file: noFile) == .queued)
    #expect(ArchiveRowState.state(
      for: archive("1"), jobs: [job("1", .running)], recordedPath: nil, file: noFile) == .running)
  }

  @Test("a finished job whose file is there is downloaded")
  func doneWithFileIsDownloaded() {
    let path = URL(filePath: "/Users/x/Downloads/a.mp4")
    let state = ArchiveRowState.state(
      for: archive("1"), jobs: [job("1", .done, files: [path])],
      recordedPath: nil, file: { _ in .present(path) })
    #expect(state == .downloaded(path))
  }

  /// §4: deleting a download un-does it. The row goes back to something you
  /// can fetch again rather than claiming you have it.
  @Test("a finished job whose file is gone is missing, not downloaded")
  func doneWithoutFileIsMissing() {
    let state = ArchiveRowState.state(
      for: archive("1"),
      jobs: [job("1", .done, files: [URL(filePath: "/Users/x/Downloads/a.mp4")])],
      recordedPath: nil, file: { _ in .absent })
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
      recordedPath: nil, file: { _ in .unknown(volumeName: "Helios") })
    #expect(state == .unverifiable(volumeName: "Helios"))
  }

  @Test("a failed job reads as failed")
  func failedJobIsFailed() {
    #expect(ArchiveRowState.state(
      for: archive("1"), jobs: [job("1", .failed)], recordedPath: nil, file: noFile) == .failed)
  }

  /// A cancellation is a person saying no, not the app having tried and
  /// lost — the same rule `AutoDownloadObserver` already keeps. The row
  /// returns to being something they can pick up again.
  @Test("a cancelled job leaves the archive available")
  func cancelledJobIsAvailableAgain() {
    #expect(ArchiveRowState.state(
      for: archive("1"), jobs: [job("1", .cancelled)], recordedPath: nil, file: noFile) == .available)
  }

  @Test("jobs for other archives are ignored")
  func otherJobsDoNotLeak() {
    #expect(ArchiveRowState.state(
      for: archive("1"), jobs: [job("2", .running)], recordedPath: nil, file: noFile) == .available)
  }

  /// Re-downloading after a delete leaves two jobs for one archive. The
  /// unfinished one is what the person is waiting on, so it wins over the
  /// finished one regardless of array order.
  @Test("an unfinished job outranks a finished one for the same archive")
  func unfinishedOutranksFinished() {
    let path = URL(filePath: "/Users/x/Downloads/a.mp4")
    let jobs = [job("1", .done, files: [path]), job("1", .running)]
    #expect(ArchiveRowState.state(
      for: archive("1"), jobs: jobs, recordedPath: nil, file: { _ in .present(path) }) == .running)
    #expect(ArchiveRowState.state(
      for: archive("1"), jobs: jobs.reversed(), recordedPath: nil, file: { _ in .present(path) }) == .running)
  }

  /// §6.3: a retried automatic download leaves the failed job in the queue
  /// and submits a new one rather than replacing it, so a done job and a
  /// failed job can legitimately coexist for the same archive. §4 of
  /// channel-history.md says the filesystem is authoritative, so the file
  /// being there wins regardless of which job comes first in the array.
  @Test("a done job with its file present outranks a coexisting failed job")
  func doneOutranksFailed() {
    let path = URL(filePath: "/Users/x/Downloads/a.mp4")
    let jobs = [job("1", .failed), job("1", .done, files: [path])]
    #expect(ArchiveRowState.state(
      for: archive("1"), jobs: jobs, recordedPath: nil, file: { _ in .present(path) }) == .downloaded(path))
    #expect(ArchiveRowState.state(
      for: archive("1"), jobs: jobs.reversed(), recordedPath: nil, file: { _ in .present(path) }) == .downloaded(path))
  }

  /// A finished job that delivered nothing cannot claim a file. Pinned
  /// because `deliveredFiles` is derived from a step's output and an
  /// interrupted run can leave it empty.
  @Test("a finished job with no delivered file is missing, not a crash")
  func doneWithNoDeliveredFileIsMissing() {
    #expect(ArchiveRowState.state(
      for: archive("1"), jobs: [job("1", .done, files: [])], recordedPath: nil, file: noFile) == .missing)
  }

  /// `isFetchable` governs more than a button: `ArchiveRow` asks it whether
  /// to offer Add… *and Ignore*, so a state left out of it is a row a person
  /// cannot dismiss either. Every case is pinned, including the two whose
  /// membership is a judgement rather than an obvious reading — `missing`
  /// (§4: deleting a download returns the archive to actionable) and `live`
  /// (§5.2: only the unattended path refuses a broadcast; a person may
  /// choose).
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

  /// **A row's history stops being a lease on the queue's cleanup.** Every
  /// other branch here reads a `Job`, so removing a finished download — an
  /// ordinary thing to do to a queue — used to erase the only evidence an
  /// archive had ever been fetched. `docs/design/video-record.md` §7 records
  /// `deliveredPath` when the job settles, so the answer outlives the job.
  @Test("a recorded path answers downloaded once the job is gone")
  func recordedPathSurvivesTheJob() {
    let path = URL(filePath: "/Volumes/Storage/wheelyf/day46.mp4")
    let state = ArchiveRowState.state(
      for: archive("1"), jobs: [],
      recordedPath: "/Volumes/Storage/wheelyf/day46.mp4",
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
      file: { _ in .unknown(volumeName: "Storage") })
    #expect(state == .unverifiable(volumeName: "Storage"))
  }

  /// §4: deleting a download un-does it, so the archive returns to actionable
  /// rather than claiming a file that is not there.
  @Test("a recorded path whose file was deleted returns to actionable")
  func deletedRecordedFileReturnsToActionable() {
    let state = ArchiveRowState.state(
      for: archive("1"), jobs: [],
      recordedPath: "/Volumes/Storage/gone.mp4",
      file: { _ in .absent })
    #expect(state == .available)
  }

  /// The case the fall-through exists for: delete the file, retry, retry
  /// fails. A stale recorded path must not answer for the archive and hide
  /// the failure, which is the more useful thing to say.
  @Test("a stale recorded path never masks a failed retry")
  func staleRecordedPathDoesNotMaskAFailure() {
    let state = ArchiveRowState.state(
      for: archive("1"), jobs: [job("1", .failed)],
      recordedPath: "/Volumes/Storage/gone.mp4",
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
      file: { url in .present(url) })
    #expect(state == .downloaded(fromJob))
  }


  /// An unmounted volume is not evidence a file was deleted — §4.1's whole
  /// point. If `unverifiable` did not count as holding a file, unplugging a
  /// disk would empty the channel that lives on it.
  @Test("only the two states with something on disk hold a file")
  func holdsAFile() {
    #expect(ArchiveRowState.downloaded(URL(filePath: "/a.mp4")).holdsAFile)
    #expect(ArchiveRowState.unverifiable(volumeName: "Storage").holdsAFile)
    for state: ArchiveRowState in [.available, .live, .queued, .running, .missing, .failed] {
      #expect(!state.holdsAFile, "\(state) has nothing on disk")
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

  /// §4: the folder being there is what makes "gone" an honest answer
  /// rather than a guess.
  @Test("a gone file with its folder present is absent")
  func fileGoneFolderPresent() {
    let answer = ArchiveRowState.FileAnswer.resolve(
      URL(filePath: "/Volumes/Helios/a.mp4"),
      fileExists: { _ in false }, folderExists: { _ in true })
    #expect(answer == .absent)
  }

  /// The case this rule exists for: an unplugged drive must read as
  /// unreachable, never as a deleted file, and the volume's name has to
  /// come from the path itself since the folder can't be asked.
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
