import Foundation
import Testing
@testable import OxbowKit

@Suite("Scheduler transitions")
struct SchedulerTransitionTests {

  private func status(_ jobs: [Job], _ n: Int) -> StepStatus {
    jobs[0].steps.first { $0.id == Build.stepID(n) }!.status
  }

  private var chatThenRender: [Job] {
    [Build.job(1,
      Build.network(1, .running),
      Build.compute(2, .queued, dependsOn: Build.stepID(1)))]
  }

  @Test func successMarksTheStepDoneAndRecordsItsArtifact() {
    var jobs = chatThenRender
    let artifact = URL(filePath: "/tmp/chat.json")
    Scheduler.complete(Build.stepID(1), with: .succeeded(artifact: artifact), in: &jobs)

    #expect(status(jobs, 1) == .done)
    #expect(jobs[0].steps[0].artifact == artifact)
  }

  @Test func failureBlocksDependentsButNotTheFailedStepItself() {
    var jobs = chatThenRender
    let failure = StepFailure(kind: .exited(code: 134), summary: "Invalid VOD")
    Scheduler.complete(Build.stepID(1), with: .failed(failure), in: &jobs)

    #expect(status(jobs, 1) == .failed(failure))
    #expect(status(jobs, 2) == .blocked)
  }

  @Test func cancellationAlsoBlocksDependents() {
    var jobs = chatThenRender
    Scheduler.complete(Build.stepID(1), with: .cancelled, in: &jobs)

    #expect(status(jobs, 1) == .cancelled)
    #expect(status(jobs, 2) == .blocked)
  }

  /// **Retrying is job-level, because cancelling is.**
  ///
  /// `cancel(job:)` settles *every* unfinished step as `.cancelled`, so
  /// retrying only the first one would requeue step 1 and leave the rest
  /// cancelled — the job would run its first step and then sit there reading
  /// as cancelled forever, with nothing left that could move it.
  @Test func retryingACancelledJobRequeuesEveryCancelledStep() {
    var jobs = chatThenRender
    Scheduler.cancel(job: Build.jobID(1), in: &jobs)
    #expect(status(jobs, 1) == .cancelled, "precondition")
    #expect(status(jobs, 2) == .cancelled, "precondition")

    Scheduler.retry(job: Build.jobID(1), in: &jobs)

    #expect(status(jobs, 1) == .queued)
    #expect(status(jobs, 2) == .queued)
  }

  /// A failed job's dependents are `.blocked` rather than cancelled, and
  /// retrying the step that failed already unblocks them. Job-level retry has
  /// to reach the same end state by the same route, not double-queue them.
  @Test func retryingAFailedJobRequeuesTheFailureAndUnblocksItsDependents() {
    var jobs = chatThenRender
    Scheduler.complete(
      Build.stepID(1),
      with: .failed(StepFailure(kind: .noArtifact, summary: "no artifact")),
      in: &jobs)

    Scheduler.retry(job: Build.jobID(1), in: &jobs)

    #expect(status(jobs, 1) == .queued)
    #expect(status(jobs, 2) == .queued)
  }

  /// Successful steps are never re-run. Retry is "start the parts that did not
  /// finish", not "start over" — re-downloading a 3GB VOD because its chat
  /// render failed would be a very expensive misunderstanding.
  @Test func retryingAJobLeavesItsFinishedStepsAlone() {
    var jobs = chatThenRender
    let artifact = URL(filePath: "/tmp/chat.json")
    Scheduler.complete(Build.stepID(1), with: .succeeded(artifact: artifact), in: &jobs)
    Scheduler.complete(Build.stepID(2), with: .cancelled, in: &jobs)

    Scheduler.retry(job: Build.jobID(1), in: &jobs)

    #expect(status(jobs, 1) == .done)
    #expect(jobs[0].steps[0].artifact == artifact)
    #expect(status(jobs, 2) == .queued)
  }

  /// Blocking must reach a dependent's dependents, not just direct children.
  @Test func blockingPropagatesTransitively() {
    var jobs = [Build.job(1,
      Build.network(1, .running),
      Build.compute(2, .queued, dependsOn: Build.stepID(1)),
      Build.compute(3, .queued, dependsOn: Build.stepID(2)))]

    Scheduler.complete(Build.stepID(1), with: .cancelled, in: &jobs)

    #expect(status(jobs, 2) == .blocked)
    #expect(status(jobs, 3) == .blocked)
  }

  /// Retry in place: requeue the failed step AND release what it blocked,
  /// without disturbing siblings that already succeeded.
  @Test func retryRequeuesTheStepAndUnblocksItsDependents() {
    var jobs = [Build.job(1,
      Build.network(9, .done),                                    // succeeded sibling
      Build.network(1, .failed(StepFailure(kind: .noArtifact, summary: "x"))),
      Build.compute(2, .blocked, dependsOn: Build.stepID(1)))]

    Scheduler.retry(Build.stepID(1), in: &jobs)

    #expect(status(jobs, 1) == .queued)
    #expect(status(jobs, 2) == .queued)
    #expect(status(jobs, 9) == .done, "a successful sibling must not be redone")
  }

  @Test func cancellingAJobCancelsEveryUnfinishedStepAndLeavesFinishedOnes() {
    var jobs = [Build.job(1,
      Build.network(1, .done),
      Build.network(2, .running),
      Build.compute(3, .queued))]

    Scheduler.cancel(job: Build.jobID(1), in: &jobs)

    #expect(status(jobs, 1) == .done)
    #expect(status(jobs, 2) == .cancelled)
    #expect(status(jobs, 3) == .cancelled)
  }

  /// After a failure the queue must keep moving on independent work.
  @Test func admissionResumesOnIndependentWorkAfterAFailure() {
    var jobs = [Build.job(1,
      Build.network(1, .running),
      Build.compute(2, .queued, dependsOn: Build.stepID(1)),
      Build.compute(3, .queued))]                                  // independent render

    Scheduler.complete(Build.stepID(1), with: .failed(
      StepFailure(kind: .noArtifact, summary: "x")), in: &jobs)

    #expect(Scheduler.admissible(jobs: jobs, running: []) == [Build.stepID(3)])
  }

  /// Retrying a `.done` step is a no-op: the artifact stays and status doesn't change.
  @Test func retryingADoneStepLeavesItDoneWithItsArtifact() {
    var step = Build.network(1, .done)
    let artifact = URL(filePath: "/tmp/chat.json")
    step.artifact = artifact
    var jobs = [Build.job(1, step)]

    Scheduler.retry(Build.stepID(1), in: &jobs)

    #expect(status(jobs, 1) == .done)
    #expect(jobs[0].steps[0].artifact == artifact)
  }

  /// Retrying a `.running` step is a no-op.
  @Test func retryingARunningStepLeavesItRunning() {
    var jobs = [Build.job(1, Build.network(1, .running))]
    Scheduler.retry(Build.stepID(1), in: &jobs)
    #expect(status(jobs, 1) == .running)
  }

  /// Retrying a `.cancelled` step requeues it and unblocks its dependents.
  @Test func retryingACancelledStepRequeuesIt() {
    var jobs = [Build.job(1,
      Build.network(1, .cancelled),
      Build.compute(2, .blocked, dependsOn: Build.stepID(1)))]

    Scheduler.retry(Build.stepID(1), in: &jobs)

    #expect(status(jobs, 1) == .queued)
    #expect(status(jobs, 2) == .queued)
  }

  /// Cancelling a `.running` step cancels it and blocks its dependents.
  @Test func cancellingARunningStepCancelsIt() {
    var jobs = [Build.job(1,
      Build.network(1, .running),
      Build.compute(2, .queued, dependsOn: Build.stepID(1)))]

    Scheduler.cancel(Build.stepID(1), in: &jobs)

    #expect(status(jobs, 1) == .cancelled)
    #expect(status(jobs, 2) == .blocked)
  }

  /// Cancelling a `.done` step is a no-op: status and artifact are preserved.
  @Test func cancellingADoneStepLeavesItDone() {
    var step = Build.network(1, .done)
    let artifact = URL(filePath: "/tmp/chat.json")
    step.artifact = artifact
    var jobs = [Build.job(1, step)]

    Scheduler.cancel(Build.stepID(1), in: &jobs)

    #expect(status(jobs, 1) == .done)
    #expect(jobs[0].steps[0].artifact == artifact)
  }
}
