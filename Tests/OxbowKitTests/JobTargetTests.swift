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

  /// **The chat step must not answer for the job.** A `.video` job seeds its
  /// `ChatRequest.videoID` with the same id (see `JobTemplate.renderInput`),
  /// so reading the first step that happens to carry a `videoID` would work
  /// by accident here — and would then read a clip job's chat step, whose
  /// `videoID` is the *slug*, or an id-less `""` for a chatless job. Only the
  /// media step is authoritative.
  @Test func aChatOnlyJobHasNoMediaIdentifier() {
    let job = makeJob(steps: [
      Step(id: stepID(), kind: .downloadChat(ChatRequest(videoID: "2820754270", format: .json))),
    ])

    #expect(job.mediaIdentifier == nil)
  }

  /// What "unfinished" means for the duplicate rule: still going to produce
  /// something. A job that failed or was cancelled is not a reason to refuse
  /// a fresh attempt — refusing one would leave the user unable to re-queue
  /// a download that went wrong, from the one surface with no queue window.
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
