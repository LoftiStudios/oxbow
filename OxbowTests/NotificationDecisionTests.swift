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

  /// Seed the initial snapshot silently so reconciled failures do not notify again at launch.
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

  /// User cancellation does not need a notification.
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

  /// Retry puts a failed job back to work. Going back to `.running` is not an
  /// event; failing a second time is.
  @Test func aRetriedJobFailingAgainNotifies() {
    let backToWork = NotificationDecision.events(
      from: [alpha: .failed],
      to: [job(alpha, [step(.running)])])
    #expect(backToWork.isEmpty)

    let failedAgain = NotificationDecision.events(
      from: [alpha: .running],
      to: [job(alpha, [step(.failed(failure))])])
    #expect(failedAgain.count == 1)
  }

  /// Nonterminal transitions must not notify.
  @Test func aJobStartingWorkNotifiesNothing() {
    let events = NotificationDecision.events(
      from: [alpha: .queued],
      to: [job(alpha, [step(.running)])])
    #expect(events.isEmpty)
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

  /// Failure notifications must omit reveal targets.
  @Test func aFailedEventCarriesNoFiles() {
    let events = NotificationDecision.events(
      from: [alpha: .running],
      to: [job(alpha, [step(.failed(failure))])])
    #expect(events.first?.files.isEmpty == true)
  }

  /// A failed job may have earlier delivered files; failure notifications must omit them
  /// explicitly.
  @Test func aFailedEventCarriesNoFilesEvenWhenAnEarlierStepDelivered() {
    let delivered = URL(filePath: "/out/a.mp4")
    let events = NotificationDecision.events(
      from: [alpha: .running],
      to: [job(alpha, [step(.done, artifact: delivered), step(.failed(failure))])])
    #expect(events.first?.outcome == .failed)
    #expect(events.first?.files.isEmpty == true)
  }
}
