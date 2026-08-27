import Foundation
import Testing
import OxbowKit
@testable import Oxbow

@Suite("Job presentation")
struct JobPresentationTests {

  private func step(_ status: StepStatus) -> Step {
    Step(
      id: StepID(rawValue: UUID()),
      kind: .downloadVideo(VideoRequest(videoID: "1", quality: "", destination: URL(filePath: "/tmp/a.mp4"))),
      status: status)
  }

  private func job(_ statuses: [StepStatus]) -> Job {
    Job(id: JobID(rawValue: UUID()), created: Date(), title: "t", steps: statuses.map(step))
  }

  @Test func prefersTheRunningStep() {
    let subject = job([.done, .running, .queued])
    #expect(JobPresentation.representativeStep(of: subject)?.status == .running)
  }

  @Test func fallsBackToTheFailedStep() {
    let failure = StepFailure(kind: .noArtifact, summary: "no artifact")
    let subject = job([.done, .failed(failure), .blocked])
    #expect(JobPresentation.representativeStep(of: subject)?.status == .failed(failure))
  }

  @Test func prefersTheRunningStepOverAFailedStep() {
    let failure = StepFailure(kind: .noArtifact, summary: "no artifact")
    let subject = job([.running, .failed(failure)])
    #expect(JobPresentation.representativeStep(of: subject)?.status == .running)
  }

  @Test func fallsBackToTheCancelledStepBeforeAQueuedStep() {
    let subject = job([.cancelled, .queued])
    #expect(JobPresentation.representativeStep(of: subject)?.status == .cancelled)
  }

  @Test func fallsBackToTheFirstPendingStep() {
    let subject = job([.done, .queued, .queued])
    #expect(JobPresentation.representativeStep(of: subject)?.status == .queued)
  }

  @Test func fallsBackToTheLastStepWhenEverythingIsDone() {
    let subject = job([.done, .done])
    #expect(JobPresentation.representativeStep(of: subject)?.id == subject.steps.last?.id)
  }

  @Test func aJobWithNoStepsHasNoRepresentativeStep() {
    #expect(JobPresentation.representativeStep(of: job([])) == nil)
  }

  /// The whole enablement rule for the composite row's Finder-reveal item
  /// (docs/design/fragmented-output.md §6): running, or settled in any way,
  /// counts as started; still queued or blocked behind something upstream
  /// does not.
  @Test(arguments: [
    (StepStatus.queued, false),
    (.blocked, false),
    (.running, true),
    (.done, true),
    (.failed(StepFailure(kind: .noArtifact, summary: "no artifact")), true),
    (.cancelled, true),
  ])
  func hasStartedMatchesWhetherAStepHasEverRun(status: StepStatus, expected: Bool) {
    #expect(JobPresentation.hasStarted(status) == expected)
  }
}
