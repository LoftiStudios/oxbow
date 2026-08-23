import Foundation
import Testing
@testable import OxbowKit

@Suite("Scheduler admission")
struct SchedulerAdmissionTests {

  @Test func admitsAQueuedStepWithNoDependency() {
    let jobs = [Build.job(1, Build.network(1))]
    #expect(Scheduler.admissible(jobs: jobs, running: []) == [Build.stepID(1)])
  }

  /// The class-aware rule: two downloads must not overlap.
  @Test func admitsOnlyOneNetworkStepAtATime() {
    let jobs = [Build.job(1, Build.network(1), Build.network(2))]
    #expect(Scheduler.admissible(jobs: jobs, running: []) == [Build.stepID(1)])
  }

  /// ...but a download and a render may, which is the whole point.
  @Test func admitsOneNetworkAndOneComputeTogether() {
    let jobs = [Build.job(1, Build.network(1), Build.compute(2))]
    let admitted = Scheduler.admissible(jobs: jobs, running: [])
    #expect(Set(admitted) == [Build.stepID(1), Build.stepID(2)])
  }

  @Test func doesNotAdmitAStepWhoseClassIsAlreadyBusy() {
    let jobs = [Build.job(1, Build.network(1, .running), Build.network(2))]
    #expect(Scheduler.admissible(jobs: jobs, running: [Build.stepID(1)]).isEmpty)
  }

  @Test func doesNotAdmitAStepWhoseDependencyIsUnfinished() {
    let jobs = [Build.job(1, Build.network(1), Build.compute(2, dependsOn: Build.stepID(1)))]
    #expect(Scheduler.admissible(jobs: jobs, running: []) == [Build.stepID(1)])
  }

  @Test func admitsAStepOnceItsDependencyIsDone() {
    let jobs = [Build.job(1, Build.network(1, .done), Build.compute(2, dependsOn: Build.stepID(1)))]
    #expect(Scheduler.admissible(jobs: jobs, running: []) == [Build.stepID(2)])
  }

  @Test(arguments: [StepStatus.running, .done, .blocked, .cancelled])
  func onlyQueuedStepsAreAdmitted(status: StepStatus) {
    let jobs = [Build.job(1, Build.network(1, status))]
    #expect(Scheduler.admissible(jobs: jobs, running: []).isEmpty)
  }

  /// Ordering must be answerable, so ties break on job creation time.
  @Test func admitsTheOlderJobFirst() {
    let jobs = [
      Build.job(1, createdAt: 200, Build.network(1)),
      Build.job(2, createdAt: 100, Build.network(2)),
    ]
    #expect(Scheduler.admissible(jobs: jobs, running: []) == [Build.stepID(2)])
  }

  /// The headline scenario from the design discussion.
  @Test func aFailedChatDownloadDoesNotStopAnIndependentVideoDownload() {
    let chatFailed = Build.network(2, .failed(StepFailure(kind: .noArtifact, summary: "x")))
    let jobs = [Build.job(1,
      Build.network(1),                                    // video, independent
      chatFailed,                                          // chat, failed
      Build.compute(3, .blocked, dependsOn: Build.stepID(2)))]

    #expect(Scheduler.admissible(jobs: jobs, running: []) == [Build.stepID(1)])
  }

  /// When two jobs have identical creation timestamps, the tie-break is on job ID.
  /// This test asserts the specific expected step is admitted, not just "something".
  @Test func tieBreakOnJobIDWhenTimestampsAreIdentical() {
    let timestamp: TimeInterval = 100
    let jobs = [
      Build.job(1, createdAt: timestamp, Build.network(1)),
      Build.job(2, createdAt: timestamp, Build.network(2)),
    ]
    // Job 1 has jobID ending in 0001, Job 2 has jobID ending in 0002
    // So Job 1's ID should sort first in string comparison
    #expect(Scheduler.admissible(jobs: jobs, running: []) == [Build.stepID(1)])
  }
}
