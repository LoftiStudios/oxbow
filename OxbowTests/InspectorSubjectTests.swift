import Foundation
import Testing
import OxbowKit
@testable import Oxbow

/// `InspectorSubject.resolve` — the whole behavioural surface of the
/// inspector, exercised without building a view.
///
/// `docs/design/inspector.md` §3.3. A `static` over plain values for the same
/// reason `WatchingModel.listings(from:)` and `ChannelCard
/// .disconnectedVolume(in:)` are: no store, no sweep, no window.
@MainActor
@Suite("Inspector subject")
struct InspectorSubjectTests {

  private func step(_ kind: StepKind, _ status: StepStatus = .queued) -> Step {
    Step(id: StepID(rawValue: UUID()), kind: kind, status: status)
  }

  /// A job whose one step is a video download, so `mediaIdentifier` answers.
  private func videoJob(
    _ title: String, videoID: String, _ status: StepStatus = .queued
  ) -> Job {
    Job(
      id: JobID(rawValue: UUID()), created: Date(timeIntervalSince1970: 0),
      title: title,
      steps: [step(.downloadVideo(VideoRequest(
        videoID: videoID, quality: "360p30",
        destination: URL(filePath: "/out/\(title).mp4"))), status)])
  }

  /// A job carrying no video or clip request at all, so `mediaIdentifier` is
  /// nil — `video-record.md` §4.2's case that must stay addressable.
  private func chatOnlyJob(_ title: String) -> Job {
    Job(
      id: JobID(rawValue: UUID()), created: Date(timeIntervalSince1970: 0),
      title: title,
      steps: [step(.downloadChat(ChatRequest(videoID: "1", format: .json)))])
  }

  @Test func nothingSelectedIsNothing() {
    #expect(InspectorSubject.resolve(
      destination: .queue, queueSelection: [], jobs: []) == .nothing)
  }

  @Test func oneQueueJobWithAVideoResolvesToThatVideo() {
    let j = videoJob("A", videoID: "123")
    #expect(InspectorSubject.resolve(
      destination: .queue, queueSelection: [j.id], jobs: [j])
      == .one(.video("123")))
  }

  /// `video-record.md` §4.2: a job with no resolvable video id stays
  /// addressable, keyed by its `JobID` instead of becoming un-openable.
  @Test func oneQueueJobWithoutAVideoResolvesToTheJob() {
    let j = chatOnlyJob("A")
    #expect(InspectorSubject.resolve(
      destination: .queue, queueSelection: [j.id], jobs: [j])
      == .one(.job(j.id)))
  }

  @Test func aSelectedIdThatMatchesNoJobIsNothing() {
    let j = videoJob("A", videoID: "123")
    #expect(InspectorSubject.resolve(
      destination: .queue, queueSelection: [JobID(rawValue: UUID())], jobs: [j])
      == .nothing)
  }

  @Test func severalSelectedCountsThemByStatus() {
    let a = videoJob("A", videoID: "1", .queued)
    let b = videoJob("B", videoID: "2", .queued)
    let c = videoJob("C", videoID: "3",
                     .failed(StepFailure(kind: .noArtifact, summary: "no artifact")))
    let subject = InspectorSubject.resolve(
      destination: .queue, queueSelection: [a.id, b.id, c.id], jobs: [a, b, c])
    guard case .many(let many) = subject else {
      Issue.record("expected .many, got \(subject)")
      return
    }
    #expect(many.count == 3)
    #expect(many.queued == 2)
    #expect(many.failed == 1)
    #expect(many.running == 0)
    #expect(many.done == 0)
    #expect(many.cancelled == 0)
  }

  /// **The estimate is not attempted yet, and absent is the honest answer.**
  /// Slice D fills it; §5.3 forbids a partial sum, so nil here is the same
  /// value it will carry whenever a selection cannot be fully priced.
  @Test func theEstimateIsAbsentUntilItCanBeComputed() {
    let a = videoJob("A", videoID: "1")
    let b = videoJob("B", videoID: "2")
    guard case .many(let many) = InspectorSubject.resolve(
      destination: .queue, queueSelection: [a.id, b.id], jobs: [a, b])
    else {
      Issue.record("expected .many")
      return
    }
    #expect(many.estimatedBytes == nil)
  }

  /// Slice C wires these up. Until then the Watching side must resolve to
  /// `.nothing` rather than to whatever the queue happens to have selected —
  /// a pane showing a queue row while you are looking at a channel is worse
  /// than a pane showing nothing.
  @Test func watchingDestinationsResolveToNothingForNow() {
    let j = videoJob("A", videoID: "1")
    #expect(InspectorSubject.resolve(
      destination: .watching, queueSelection: [j.id], jobs: [j]) == .nothing)
    #expect(InspectorSubject.resolve(
      destination: .channel("leighxp"), queueSelection: [j.id], jobs: [j])
      == .nothing)
  }

  @Test func noDestinationIsNothing() {
    let j = videoJob("A", videoID: "1")
    #expect(InspectorSubject.resolve(
      destination: nil, queueSelection: [j.id], jobs: [j]) == .nothing)
  }
}
