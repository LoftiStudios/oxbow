import Foundation
import Testing
@testable import OxbowKit

@Suite("Reconciler")
struct ReconcilerTests {

  private func status(_ jobs: [Job], _ n: Int) -> StepStatus {
    jobs[0].steps.first { $0.id == Build.stepID(n) }!.status
  }

  /// Persisted running steps become interrupted; retry handles resumable output separately.
  @Test func runningStepsBecomeInterrupted() {
    let jobs = [Build.job(1, Build.network(1, .running))]
    let out = Reconciler.reconcile(jobs) { _ in true }
    #expect(out[0].steps[0].status == .failed(StepFailure(kind: .interrupted, summary: "Interrupted")))
  }

  /// The check that stops a finished 4 GB download being redone.
  @Test func doneStepsKeepTheirStatusWhenTheArtifactStillExists() {
    var step = Build.network(1, .done)
    step.artifact = URL(filePath: "/Users/me/Movies/v.mp4")
    let out = Reconciler.reconcile([Build.job(1, step)]) { _ in true }
    #expect(status(out, 1) == .done)
  }

  /// Keep the job unfinished so reconciliation examines its missing intermediate; all-done jobs
  /// are exempt.
  @Test func doneStepsRequeueWhenTheirArtifactVanished() {
    var step = Build.network(1, .done)
    step.artifact = URL(filePath: "/tmp/gone/chat.json")
    let out = Reconciler.reconcile([Build.job(1, step, Build.compute(2, .queued))]) { _ in false }
    #expect(status(out, 1) == .queued)
    #expect(out[0].steps[0].artifact == nil)
  }

  @Test func doneStepsWithNoRecordedArtifactRequeue() {
    let jobs = [Build.job(1, Build.network(1, .done), Build.compute(2, .queued))]
    let out = Reconciler.reconcile(jobs) { _ in true }
    #expect(status(out, 1) == .queued)
  }

  /// Completed jobs must not reopen because intentionally discarded intermediates are absent.
  @Test func finishedJobsAreNeverRequeued() {
    var chat = Build.network(1, .done)
    chat.artifact = URL(filePath: "/tmp/gone/chat.json")
    var render = Build.compute(2, .done, dependsOn: [Build.stepID(1)])
    render.artifact = URL(filePath: "/Users/me/Movies/render.mp4")

    let out = Reconciler.reconcile([Build.job(1, chat, render)]) { _ in false }

    #expect(status(out, 1) == .done, "the discarded intermediate must not un-finish the job")
    #expect(status(out, 2) == .done)
    #expect(out[0].status == .done)
  }

  /// Failed jobs remain retryable and must re-fetch missing inputs.
  @Test func failedJobsStillRequeueADoneStepWhoseArtifactVanished() {
    var chat = Build.network(1, .done)
    chat.artifact = URL(filePath: "/tmp/gone/chat.json")
    let render = Build.compute(2, .failed(StepFailure(kind: .noArtifact, summary: "no")),
      dependsOn: [Build.stepID(1)])

    let out = Reconciler.reconcile([Build.job(1, chat, render)]) { _ in false }

    #expect(status(out, 1) == .queued)
  }

  @Test(arguments: [StepStatus.queued, .blocked, .cancelled])
  func otherStatusesAreLeftAlone(status input: StepStatus) {
    let out = Reconciler.reconcile([Build.job(1, Build.network(1, input))]) { _ in true }
    #expect(status(out, 1) == input)
  }
}
