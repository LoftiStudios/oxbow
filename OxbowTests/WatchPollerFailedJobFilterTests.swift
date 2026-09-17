import Foundation
import Testing
import OxbowKit
@testable import Oxbow

/// Exclude failed jobs from unattended resubmission. Unmarking returns them for manual retry;
/// without this filter each sweep would retry the same failure indefinitely.
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

  /// Cancellation does not participate in the failed-job retry filter.
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
