import Foundation
import Testing
@testable import OxbowKit

@Suite("Domain model")
struct ModelTests {

  private func step(_ status: StepStatus) -> Step {
    Step(
      id: StepID(rawValue: UUID()),
      kind: .downloadChat(ChatRequest(videoID: "1", format: .json)),
      status: status,
      progress: StepProgress(),
      dependsOn: nil,
      artifact: nil)
  }

  private func job(_ statuses: [StepStatus]) -> Job {
    Job(
      id: JobID(rawValue: UUID()),
      created: Date(timeIntervalSince1970: 0),
      title: "t",
      steps: statuses.map(step))
  }

  @Test func downloadsAreNetworkAndRendersAreCompute() {
    #expect(StepKind.downloadVideo(VideoRequest(
      videoID: "1", quality: "160p30", destination: URL(filePath: "/tmp/a"))).resource == .network)
    #expect(StepKind.downloadClip(ClipRequest(
      clipSlug: "s", quality: "480p", destination: URL(filePath: "/tmp/a"))).resource == .network)
    #expect(StepKind.downloadChat(ChatRequest(videoID: "1", format: .json)).resource == .network)
    #expect(StepKind.renderChat(RenderRequest(destination: URL(filePath: "/tmp/a"))).resource == .compute)
  }

  @Test func jobStatusIsRunningWheneverAnyStepRuns() {
    #expect(job([.done, .running, .queued]).status == .running)
  }

  @Test func jobStatusIsDoneOnlyWhenEveryStepIsDone() {
    #expect(job([.done, .done]).status == .done)
    #expect(job([.done, .queued]).status == .queued)
  }

  /// A blocked step means something upstream failed, so the job reads failed.
  @Test func jobStatusIsFailedWhenAnyStepFailedOrIsBlocked() {
    #expect(job([.done, .failed(StepFailure(kind: .noArtifact, summary: "x"))]).status == .failed)
    #expect(job([.done, .blocked]).status == .failed)
  }

  @Test func jobStatusIsCancelledWhenAStepWasCancelledAndNoneFailed() {
    #expect(job([.done, .cancelled]).status == .cancelled)
  }

  /// Everything persisted must survive a round trip; the queue file depends on it.
  @Test func jobRoundTripsThroughCodable() throws {
    let original = job([.queued, .done, .failed(StepFailure(kind: .exited(code: 134), summary: "boom"))])
    let data = try JSONEncoder().encode(original)
    let decoded = try JSONDecoder().decode(Job.self, from: data)
    #expect(decoded == original)
  }
}
