import Foundation
import Testing
import OxbowKit
@testable import Oxbow

@Suite("Queue status")
struct QueueStatusTests {

  // MARK: - Fixtures

  /// `QueueStatus` never reads `kind`, only status and progress, so one kind
  /// serves every case here.
  private func step(_ status: StepStatus, fraction: Double? = nil) -> Step {
    Step(
      id: StepID(rawValue: UUID()),
      kind: .downloadVideo(VideoRequest(
        videoID: "1", quality: "", destination: URL(filePath: "/tmp/a.mp4"))),
      status: status,
      progress: StepProgress(fraction: fraction))
  }

  private func job(_ steps: [Step], created: TimeInterval = 0) -> Job {
    Job(
      id: JobID(rawValue: UUID()),
      created: Date(timeIntervalSince1970: created),
      title: "t",
      steps: steps)
  }

  /// **Quantization off.** A zero quantum is the documented degenerate case
  /// and passes the fraction through unchanged, which is what these tests
  /// want: they are about which step the bar follows, not about rounding.
  ///
  /// Do not "improve" this to a realistic quantum. At 1/128 a fraction of
  /// 0.4 becomes 0.3984375, and every bar assertion below would have to
  /// carry a rounded literal that says nothing about the rule it is testing.
  /// Rounding has its own section further down.
  private func status(_ jobs: [Job]) -> QueueStatus {
    QueueStatus(jobs: jobs, quantum: 0)
  }

  private let failure = StepFailure(kind: .noArtifact, summary: "no artifact")

  // MARK: - Idle

  @Test func anEmptyQueueIsIdle() {
    let subject = status([])
    #expect(subject.badge == nil)
    #expect(subject.bar == .hidden)
    #expect(subject.isIdle)
  }

  @Test func aQueueOfFinishedJobsIsIdle() {
    #expect(status([job([step(.done)]), job([step(.done)])]).isIdle)
  }

  /// A cancelled job asked for nothing and is not outstanding.
  @Test func aCancelledJobIsNotOutstanding() {
    #expect(status([job([step(.cancelled)])]).isIdle)
  }

  // MARK: - The count

  /// Spec §3: with a single job the bar tells the whole story, and a badge
  /// reading "1" adds a glyph without adding information.
  @Test func oneOutstandingJobShowsNoCount() {
    #expect(status([job([step(.running, fraction: 0.5)])]).badge == nil)
  }

  @Test func twoOutstandingJobsShowTheCount() {
    let subject = status([
      job([step(.running, fraction: 0.5)], created: 0),
      job([step(.queued)], created: 1)])
    #expect(subject.badge == .count(2))
  }

  @Test func theCountIncludesQueuedAndRunningAndNothingElse() {
    let subject = status([
      job([step(.running, fraction: 0.5)], created: 0),
      job([step(.queued)], created: 1),
      job([step(.queued)], created: 2),
      job([step(.done)], created: 3),
      job([step(.cancelled)], created: 4)])
    #expect(subject.badge == .count(3))
  }

  // MARK: - Failure

  /// Spec §3: failure is sticky and wins outright.
  @Test func aFailureOverridesTheCount() {
    let subject = status([
      job([step(.running, fraction: 0.5)], created: 0),
      job([step(.queued)], created: 1),
      job([step(.failed(failure))], created: 2)])
    #expect(subject.badge == .alert)
  }

  @Test func aFailureAloneShowsTheAlert() {
    #expect(status([job([step(.failed(failure))])]).badge == .alert)
  }

  /// Spec §3: jobs 1 and 2 can be running while job 3 has failed. Dropping
  /// the bar there would hide live work behind a failure not blocking it.
  @Test func aFailureDoesNotSuppressTheBar() {
    let subject = status([
      job([step(.running, fraction: 0.5)], created: 0),
      job([step(.failed(failure))], created: 1)])
    #expect(subject.bar == .fraction(0.5))
  }

  /// A blocked step reads as a failed job from outside, and must badge.
  @Test func aBlockedStepMakesTheJobAlert() {
    #expect(status([job([step(.failed(failure)), step(.blocked)])]).badge == .alert)
  }

  // MARK: - The bar

  @Test func anIdleQueueHasNoBar() {
    #expect(status([job([step(.queued)])]).bar == .hidden)
  }

  @Test func theBarTakesTheRunningStepsFraction() {
    #expect(status([job([step(.running, fraction: 0.25)])]).bar == .fraction(0.25))
  }

  /// Spec §4.2: an absent bar reads as idle, which is a lie while a chat
  /// download is running. An empty track says "working, no estimate".
  @Test func aRunningStepWithNoFractionIsIndeterminate() {
    #expect(status([job([step(.running, fraction: nil)])]).bar == .indeterminate)
  }

  /// Spec §4.1: oldest running job, and within it the representative step.
  @Test func theBarFollowsTheOldestRunningJob() {
    let subject = status([
      job([step(.running, fraction: 0.75)], created: 10),
      job([step(.running, fraction: 0.25)], created: 20)])
    #expect(subject.bar == .fraction(0.75))
  }

  /// A queued job created earlier must not win over a running one.
  @Test func theBarIgnoresJobsThatAreNotRunning() {
    let subject = status([
      job([step(.queued)], created: 0),
      job([step(.running, fraction: 0.4)], created: 10)])
    #expect(subject.bar == .fraction(0.4))
  }

  /// Spec §4.1: the Dock uses `JobPresentation`'s rule rather than a second
  /// one of its own. Within a running job that is the running step.
  @Test func theBarUsesTheRepresentativeStepWithinAJob() {
    let subject = status([job([
      step(.done, fraction: 1),
      step(.running, fraction: 0.3),
      step(.queued)])])
    #expect(subject.bar == .fraction(0.3))
  }

  // MARK: - Quantization

  /// Spec §6: two snapshots that would draw the same pixels compare equal,
  /// so `Equatable` throttles redraws with no timer.
  @Test func fractionsWithinOneQuantumCompareEqual() {
    let a = QueueStatus(jobs: [job([step(.running, fraction: 0.5000)])], quantum: 0.01)
    let b = QueueStatus(jobs: [job([step(.running, fraction: 0.5090)])], quantum: 0.01)
    #expect(a == b)
  }

  @Test func fractionsAcrossAQuantumBoundaryDiffer() {
    let a = QueueStatus(jobs: [job([step(.running, fraction: 0.5000)])], quantum: 0.01)
    let b = QueueStatus(jobs: [job([step(.running, fraction: 0.5100)])], quantum: 0.01)
    #expect(a != b)
  }

  /// Rounds down, so the bar never overstates progress.
  @Test func quantizationRoundsDown() {
    #expect(QueueStatus.quantize(0.999, to: 0.1) == 0.9)
  }

  @Test func aCompleteFractionSurvivesQuantization() {
    #expect(QueueStatus.quantize(1, to: 1.0 / 128) == 1)
  }

  @Test func fractionsAreClampedToTheUnitRange() {
    #expect(QueueStatus.quantize(1.4, to: 0.01) == 1)
    #expect(QueueStatus.quantize(-0.2, to: 0.01) == 0)
  }

  /// A degenerate quantum must not divide by zero or hang.
  @Test func aZeroQuantumIsTolerated() {
    #expect(QueueStatus.quantize(0.42, to: 0) == 0.42)
  }
}
