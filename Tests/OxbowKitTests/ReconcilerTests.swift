import Foundation
import Testing
@testable import OxbowKit

@Suite("Reconciler")
struct ReconcilerTests {

  private func status(_ jobs: [Job], _ n: Int) -> StepStatus {
    jobs[0].steps.first { $0.id == Build.stepID(n) }!.status
  }

  /// Nothing resumes, so a step persisted as running died with the app.
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

  /// An intermediate that only ever lived in the job workspace is gone.
  @Test func doneStepsRequeueWhenTheirArtifactVanished() {
    var step = Build.network(1, .done)
    step.artifact = URL(filePath: "/tmp/gone/chat.json")
    let out = Reconciler.reconcile([Build.job(1, step)]) { _ in false }
    #expect(status(out, 1) == .queued)
    #expect(out[0].steps[0].artifact == nil)
  }

  @Test func doneStepsWithNoRecordedArtifactRequeue() {
    let out = Reconciler.reconcile([Build.job(1, Build.network(1, .done))]) { _ in true }
    #expect(status(out, 1) == .queued)
  }

  @Test(arguments: [StepStatus.queued, .blocked, .cancelled])
  func otherStatusesAreLeftAlone(status input: StepStatus) {
    let out = Reconciler.reconcile([Build.job(1, Build.network(1, input))]) { _ in true }
    #expect(status(out, 1) == input)
  }
}
