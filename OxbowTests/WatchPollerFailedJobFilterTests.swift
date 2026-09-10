import Foundation
import Testing
import OxbowKit
@testable import Oxbow

/// `WatchPoller.excludingArchivesWithFailedJobs` — finding 1 of the final
/// stage-3 review. Not a general `WatchPollerTests` suite: the rest of
/// `WatchPoller` is timing and wiring over `QueueHost`'s singleton, and
/// stays covered the way `docs/design/channel-watching.md` §9.1 already
/// describes for that layer (verified by hand). This one function is pure
/// and was pulled out specifically so this narrow, high-severity fix could
/// be pinned without a store, a clock, or an engine.
///
/// **The bug this closes.** `AutoDownloadObserver.forget` un-marks a failed
/// automatic download's archive from `seen` so a person can retry it
/// deliberately. Without this filter, the very next sweep loads the watch
/// fresh, sees the archive as unseen again, and resubmits it unattended —
/// `IntentSubmission.submit`'s duplicate guard only blocks *unfinished*
/// jobs, so the finished `.failed` job blocks nothing. It fails the same
/// way, gets un-marked again, and the cycle repeats every poll interval for
/// the archive's entire retention window.
@Suite("WatchPoller excludes archives with a failed job")
struct WatchPollerFailedJobFilterTests {

  private func archive(_ id: String) -> ChannelArchive {
    ChannelArchive(id: id, title: "t", duration: .seconds(60),
                   publishedAt: Date(timeIntervalSince1970: 0), status: .recorded, thumbnailURL: nil)
  }

  private func step(_ status: StepStatus, videoID: String) -> Step {
    Step(
      id: StepID(rawValue: UUID()),
      kind: .downloadVideo(VideoRequest(
        videoID: videoID, quality: "", destination: URL(filePath: "/out/a.mp4"))),
      status: status)
  }

  private func job(_ steps: [Step]) -> Job {
    Job(id: JobID(rawValue: UUID()), created: Date(timeIntervalSince1970: 0), title: "Stream", steps: steps)
  }

  private let failure = StepFailure(kind: .noArtifact, summary: "no artifact")

  @Test("a finding whose media has a failed job is excluded")
  func excludesAFindingWithAFailedJob() {
    let jobs = [job([step(.failed(failure), videoID: "1")])]
    let result = WatchPoller.excludingArchivesWithFailedJobs([archive("1"), archive("2")], jobs: jobs)
    #expect(result.map(\.id) == ["2"])
  }

  @Test("a finding with no job at all is still offered")
  func offersAFindingWithNoJob() {
    let result = WatchPoller.excludingArchivesWithFailedJobs([archive("1")], jobs: [])
    #expect(result.map(\.id) == ["1"])
  }

  /// §6.3: a cancellation is a person saying no, not the app having tried
  /// and lost, so it must not block a future unattended attempt the way a
  /// real failure does — the identical distinction
  /// `AutoDownloadObserver.mediaIdentifiersAlreadyAnswered` already draws.
  @Test("a finding with only a cancelled job is still offered")
  func offersAFindingWithOnlyACancelledJob() {
    let jobs = [job([step(.cancelled, videoID: "1")])]
    let result = WatchPoller.excludingArchivesWithFailedJobs([archive("1")], jobs: jobs)
    #expect(result.map(\.id) == ["1"])
  }

  @Test("a failed job for a different archive does not exclude this one")
  func aFailureForAnUnrelatedArchiveDoesNotExcludeThisOne() {
    let jobs = [job([step(.failed(failure), videoID: "other")])]
    let result = WatchPoller.excludingArchivesWithFailedJobs([archive("1")], jobs: jobs)
    #expect(result.map(\.id) == ["1"])
  }
}
