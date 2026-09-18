import Foundation
import Testing
@testable import OxbowKit

@Suite("Job targets")
struct JobTargetTests {

  /// The identifier a duplicate check compares against. A VOD job's is its
  /// video id, wherever in the job that id appears.
  @Test func aVideoJobReportsItsVideoID() {
    let job = makeJob(steps: [
      Step(id: stepID(), kind: .downloadVideo(VideoRequest(videoID: "2820754270", quality: ""))),
    ])

    #expect(job.mediaIdentifier == "2820754270")
  }

  @Test func aClipJobReportsItsSlug() {
    let job = makeJob(steps: [
      Step(id: stepID(), kind: .downloadClip(ClipRequest(clipSlug: "SpicySlug", quality: ""))),
    ])

    #expect(job.mediaIdentifier == "SpicySlug")
  }

  /// Media identity comes from the media step, not whichever chat request appears first.
  @Test func aChatOnlyJobHasNoMediaIdentifier() {
    let job = makeJob(steps: [
      Step(id: stepID(), kind: .downloadChat(ChatRequest(videoID: "2820754270", format: .json))),
    ])

    #expect(job.mediaIdentifier == nil)
  }

  /// Failed/cancelled jobs must permit fresh intent submissions; only unfinished work blocks
  /// duplicates.
  @Test func queuedAndRunningJobsAreUnfinished() {
    #expect(JobStatus.queued.isUnfinished)
    #expect(JobStatus.running.isUnfinished)
  }

  @Test func doneFailedAndCancelledJobsAreNot() {
    #expect(!JobStatus.done.isUnfinished)
    #expect(!JobStatus.failed.isUnfinished)
    #expect(!JobStatus.cancelled.isUnfinished)
  }

  // MARK: - Fixtures

  private func makeJob(steps: [Step]) -> Job {
    Job(id: JobID(rawValue: UUID()), created: Date(), title: "A Stream", steps: steps)
  }

  private func stepID() -> StepID { StepID(rawValue: UUID()) }
}
