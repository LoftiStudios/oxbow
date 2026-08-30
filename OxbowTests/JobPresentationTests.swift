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

  // MARK: - Tones

  /// A queued step is not a warning. Nothing is wrong with it and nothing is
  /// asked of the user — it is simply waiting its turn, which in an expanded
  /// composite job is three or four rows at once. Orange there reads as a
  /// list of problems.
  @Test func aQueuedStepIsPendingRatherThanAWarning() {
    #expect(JobPresentation.icon(for: StepStatus.queued).tone == .pending)
  }

  @Test func aQueuedJobIsPendingRatherThanAWarning() {
    #expect(JobPresentation.icon(for: JobStatus.queued).tone == .pending)
  }

  /// The distinction the second grey exists for: a queued step is going to
  /// run, a blocked or cancelled one never will. Collapsing them onto one
  /// tone would leave the glyph as the only thing saying so.
  @Test func stepsThatWillNeverRunAreInertRatherThanPending() {
    #expect(JobPresentation.icon(for: StepStatus.blocked).tone == .neutral)
    #expect(JobPresentation.icon(for: StepStatus.cancelled).tone == .neutral)
    #expect(JobPresentation.icon(for: StepStatus.queued).tone != .neutral)
  }
}
