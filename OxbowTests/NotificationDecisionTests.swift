import Foundation
import Testing
import OxbowKit
@testable import Oxbow

@Suite("Notification decision")
struct NotificationDecisionTests {

  private let failure = StepFailure(kind: .noArtifact, summary: "no artifact")

  private func step(_ status: StepStatus, artifact: URL? = nil) -> Step {
    Step(
      id: StepID(rawValue: UUID()),
      kind: .downloadVideo(VideoRequest(
        videoID: "1", quality: "", destination: URL(filePath: "/out/a.mp4"))),
      status: status,
      artifact: artifact)
  }

  private func job(
    _ id: JobID,
    _ steps: [Step],
    title: String = "Stream")
    -> Job
  {
    Job(id: id, created: Date(timeIntervalSince1970: 0), title: title, steps: steps)
  }

  private let alpha = JobID(rawValue: UUID())
  private let beta = JobID(rawValue: UUID())

  // MARK: - Seeding

  /// Spec §7.1. `QueueEngine.start()` reconciles before publishing, so the
  /// first snapshot after launch routinely contains freshly-failed jobs.
  /// Without seeding, every launch after an interrupted run notifies about
  /// something that happened yesterday.
  @Test func theFirstSnapshotNotifiesNothing() {
    let snapshot = [
      job(alpha, [step(.failed(failure))]),
      job(beta, [step(.done)])]
    #expect(NotificationDecision.events(from: [:], to: snapshot).isEmpty)
  }

  @Test func theFirstSnapshotStillYieldsAFullBaseline() {
    let snapshot = [job(alpha, [step(.running)]), job(beta, [step(.queued)])]
    let baseline = NotificationDecision.statuses(of: snapshot)
    #expect(baseline == [alpha: .running, beta: .queued])
  }

  // MARK: - Transitions

  @Test func aJobReachingDoneNotifies() {
    let events = NotificationDecision.events(
      from: [alpha: .running],
      to: [job(alpha, [step(.done, artifact: URL(filePath: "/out/a.mp4"))])])
    #expect(events.count == 1)
    #expect(events.first?.outcome == .finished)
    #expect(events.first?.job == alpha)
  }

  @Test func aJobReachingFailedNotifies() {
    let events = NotificationDecision.events(
      from: [alpha: .running],
      to: [job(alpha, [step(.failed(failure))])])
    #expect(events.first?.outcome == .failed)
  }

  /// Telling someone the thing they just cancelled is cancelled is the app
  /// talking to itself.
  @Test func aCancelledJobIsSilent() {
    let events = NotificationDecision.events(
      from: [alpha: .running],
      to: [job(alpha, [step(.cancelled)])])
    #expect(events.isEmpty)
  }

  @Test func anUnchangedSnapshotNotifiesNothing() {
    let events = NotificationDecision.events(
      from: [alpha: .done],
      to: [job(alpha, [step(.done)])])
    #expect(events.isEmpty)
  }

  @Test func aNewlyEnqueuedJobNotifiesNothing() {
    let events = NotificationDecision.events(
      from: [alpha: .done],
      to: [job(alpha, [step(.done)]), job(beta, [step(.queued)])])
    #expect(events.isEmpty)
  }

  /// A job that disappears did not finish; it was deleted.
  @Test func aRemovedJobNotifiesNothing() {
    #expect(NotificationDecision.events(from: [alpha: .running], to: []).isEmpty)
  }

  /// Retry puts a failed job back to work; failing again is a new event.
  @Test func aRetriedJobFailingAgainNotifies() {
    let events = NotificationDecision.events(
      from: [alpha: .running],
      to: [job(alpha, [step(.failed(failure))])])
    #expect(events.count == 1)
  }

  @Test func severalJobsSettlingAtOnceEachNotify() {
    let events = NotificationDecision.events(
      from: [alpha: .running, beta: .running],
      to: [job(alpha, [step(.done)]), job(beta, [step(.failed(failure))])])
    #expect(events.count == 2)
  }

  // MARK: - Payload

  @Test func aFinishedEventCarriesTheJobsTitleAndDeliveredFiles() {
    let delivered = URL(filePath: "/out/a.mp4")
    let events = NotificationDecision.events(
      from: [alpha: .running],
      to: [job(alpha, [step(.done, artifact: delivered)], title: "LeighXP")])
    #expect(events.first?.title == "LeighXP")
    #expect(events.first?.files == [delivered])
  }

  /// A failed job delivered nothing, so the reveal action has no target.
  @Test func aFailedEventCarriesNoFiles() {
    let events = NotificationDecision.events(
      from: [alpha: .running],
      to: [job(alpha, [step(.failed(failure))])])
    #expect(events.first?.files.isEmpty == true)
  }
}
