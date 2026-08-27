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
      dependsOn: [],
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

  /// The precedence is load-bearing: failed/blocked beats cancelled. A job with both
  /// must report failed, not cancelled.
  @Test func jobStatusPrefersFailedOverCancelledWhenBothArePresent() {
    #expect(job([.failed(StepFailure(kind: .noArtifact, summary: "x")), .cancelled]).status == .failed)
    #expect(job([.blocked, .cancelled]).status == .failed)
  }

  /// Running beats everything — a job still doing work never reads as finished.
  @Test func jobStatusPrefersRunningOverFailedWhenBothArePresent() {
    #expect(job([.running, .failed(StepFailure(kind: .noArtifact, summary: "x"))]).status == .running)
  }

  /// Everything persisted must survive a round trip; the queue file depends on it.
  /// This includes Duration values which are critical to the model.
  @Test func jobRoundTripsThroughCodable() throws {
    let original = job([.queued, .done, .failed(StepFailure(kind: .exited(code: 134), summary: "boom"))])
    let data = try JSONEncoder().encode(original)
    let decoded = try JSONDecoder().decode(Job.self, from: data)
    #expect(decoded == original)
  }

  /// Duration fields must be preserved exactly across encoding and decoding.
  @Test func durationFieldsRoundTripThroughCodable() throws {
    let chatStep = Step(
      id: StepID(rawValue: UUID()),
      kind: .downloadChat(ChatRequest(
        videoID: "123",
        trimStart: .seconds(5.5),
        trimEnd: .seconds(120),
        format: .json)),
      status: .done,
      progress: StepProgress(elapsed: .seconds(10), remaining: .seconds(5)),
      dependsOn: [],
      artifact: URL(filePath: "/tmp/chat.json"))

    let videoStep = Step(
      id: StepID(rawValue: UUID()),
      kind: .downloadVideo(VideoRequest(
        videoID: "456",
        quality: "720p",
        trimStart: .seconds(30),
        trimEnd: .seconds(180),
        destination: URL(filePath: "/tmp/video.mp4"))),
      status: .running,
      progress: StepProgress(elapsed: .seconds(15), remaining: .seconds(45)),
      dependsOn: [],
      artifact: nil)

    let original = Job(
      id: JobID(rawValue: UUID()),
      created: Date(timeIntervalSince1970: 0),
      title: "duration test",
      steps: [chatStep, videoStep])

    let data = try JSONEncoder().encode(original)
    let decoded = try JSONDecoder().decode(Job.self, from: data)

    #expect(decoded == original)
    #expect(decoded.steps[0].progress.elapsed == .seconds(10))
    #expect(decoded.steps[0].progress.remaining == .seconds(5))
    #expect(decoded.steps[1].progress.elapsed == .seconds(15))
    #expect(decoded.steps[1].progress.remaining == .seconds(45))

    if case .downloadChat(let chatReq) = decoded.steps[0].kind {
      #expect(chatReq.trimStart == .seconds(5.5))
      #expect(chatReq.trimEnd == .seconds(120))
    } else {
      Issue.record("wrong step kind")
    }

    if case .downloadVideo(let videoReq) = decoded.steps[1].kind {
      #expect(videoReq.trimStart == .seconds(30))
      #expect(videoReq.trimEnd == .seconds(180))
    } else {
      Issue.record("wrong step kind")
    }
  }

  // MARK: - What a step, and a job, actually delivered

  private static let folder = URL(filePath: "/Users/someone/Downloads")

  private func step(_ kind: StepKind, artifact: URL? = nil) -> Step {
    Step(id: StepID(rawValue: UUID()), kind: kind, status: .done, artifact: artifact)
  }

  /// The ordinary case: a step whose kind carries a destination, once it has
  /// succeeded, delivered exactly the file it was moved to.
  @Test func deliveredArtifactIsTheArtifactOfAStepWithADestination() {
    let destination = Self.folder.appending(path: "a.mp4")
    let video = VideoRequest(videoID: "1", quality: "", destination: destination)
    #expect(step(.downloadVideo(video), artifact: destination).deliveredArtifact == destination)
  }

  /// A step that only feeds a later one (`JobTemplate.makeJob`'s implied
  /// chat/render requests) carries `destination: nil` on its request, so
  /// `QueueEngine.move` never moves its output anywhere — but it is still
  /// `.done`, with `artifact` pointing at wherever it landed inside the job
  /// workspace. That must never read as delivered.
  @Test func deliveredArtifactIsNilForAStepWithNoDestinationEvenWhenDone() {
    let chat = ChatRequest(videoID: "1", format: .json, destination: nil)
    let workspacePath = URL(filePath: "/Caches/studio.lofti.Oxbow/jobs/x/artifacts/chat.json")
    #expect(step(.downloadChat(chat), artifact: workspacePath).deliveredArtifact == nil)
  }

  /// `.composite` always counts as having no destination, whatever
  /// `CompositeRequest.destination` says — its own output is a retained
  /// piece, not the delivered file (`StepKind.deliveryDestination`).
  @Test func deliveredArtifactIsNilForACompositeStepEvenWithAnArtifact() {
    let piece = URL(filePath: "/Caches/studio.lofti.Oxbow/resume/abc/piece-0.mp4")
    let composite = CompositeRequest(
      framerate: 30, bitrateMbps: 8, duration: .seconds(60),
      destination: Self.folder.appending(path: "out.mp4"))
    #expect(step(.composite(composite), artifact: piece).deliveredArtifact == nil)
  }

  /// A job with several genuinely separate outputs — video, chat, and a
  /// render, each with its own destination — delivers all of them, in step
  /// order.
  @Test func jobDeliveredFilesListsEveryStepThatActuallyDelivered() {
    let video = Self.folder.appending(path: "a.mp4")
    let chat = Self.folder.appending(path: "a - chat.json")
    let subject = Job(
      id: JobID(rawValue: UUID()), created: .now, title: "t",
      steps: [
        step(.downloadVideo(VideoRequest(
          videoID: "1", quality: "", destination: video)), artifact: video),
        step(.downloadChat(ChatRequest(
          videoID: "1", format: .json, destination: chat)), artifact: chat),
      ])

    #expect(subject.deliveredFiles == [video, chat])
  }

  /// The composite/assemble split: only the file `.assemble` produced counts
  /// as delivered, even though the composite step's own `artifact` still
  /// points at a retained piece.
  @Test func jobDeliveredFilesExcludesTheCompositesPieceButIncludesTheAssembledFile() {
    let piece = URL(filePath: "/Caches/studio.lofti.Oxbow/resume/abc/piece-0.mp4")
    let destination = Self.folder.appending(path: "out.mp4")
    let composite = CompositeRequest(
      framerate: 30, bitrateMbps: 8, duration: .seconds(60), destination: destination)
    let subject = Job(
      id: JobID(rawValue: UUID()), created: .now, title: "t",
      steps: [
        step(.composite(composite), artifact: piece),
        step(.assemble(AssembleRequest(destination: destination)), artifact: destination),
      ])

    #expect(subject.deliveredFiles == [destination])
  }
}
