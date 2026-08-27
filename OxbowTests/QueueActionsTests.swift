import Foundation
import Testing
import OxbowKit
@testable import Oxbow

@MainActor
@Suite("Queue actions")
struct QueueActionsTests {

  // MARK: - Fixtures

  private static let folder = URL(filePath: "/Users/someone/Downloads")

  private func step(_ kind: StepKind, _ status: StepStatus = .done, artifact: URL? = nil) -> Step {
    Step(id: StepID(rawValue: UUID()), kind: kind, status: status, artifact: artifact)
  }

  private func job(_ steps: Step...) -> Job {
    Job(id: JobID(rawValue: UUID()), created: .now, title: "t", steps: steps)
  }

  private func actions(for jobs: [Job]) -> QueueActions {
    QueueActions(
      jobs: jobs, selection: [], remove: { _ in }, retry: { _ in }, cancel: { _ in },
      showInfo: { _ in })
  }

  // MARK: - Show in Finder's file list

  @Test func deliveredFilesListsOnlyStepsThatActuallyDelivered() {
    let delivered = Self.folder.appending(path: "a.mp4")
    let subject = job(
      step(.downloadVideo(VideoRequest(
        videoID: "1", quality: "", destination: delivered)), artifact: delivered),
      step(.downloadChat(ChatRequest(videoID: "1", format: .json)), .queued))

    let jobs = [subject]
    #expect(actions(for: jobs).deliveredFiles(in: [subject.id]) == [delivered])
  }

  /// The bug this fix exists for: while a composite job is still running,
  /// its video, chat, and render steps carry `destination: nil`
  /// (`JobTemplate.makeJob`), so `QueueEngine.move` never moves them and
  /// their `artifact` still points inside the job workspace once each is
  /// `.done`. "Show in Finder" must reveal none of that — an in-progress
  /// composite job has delivered nothing yet.
  @Test func anInProgressCompositeJobRevealsNothing() {
    let video = VideoRequest(videoID: "1", quality: "1080p60", destination: nil)
    let workspaceVideo = URL(filePath: "/Caches/studio.lofti.Oxbow/jobs/x/artifacts/video.mp4")
    let workspaceChat = URL(filePath: "/Caches/studio.lofti.Oxbow/jobs/x/artifacts/chat.json")
    let workspaceRender = URL(filePath: "/Caches/studio.lofti.Oxbow/jobs/x/artifacts/render.mp4")
    let subject = job(
      step(.downloadVideo(video), artifact: workspaceVideo),
      step(.downloadChat(ChatRequest(videoID: "1", format: .json, destination: nil)), artifact: workspaceChat),
      step(.renderChat(RenderRequest(destination: nil)), artifact: workspaceRender),
      step(
        .composite(CompositeRequest(
          framerate: 60, bitrateMbps: 6, duration: .seconds(600),
          destination: Self.folder.appending(path: "out.mp4"))),
        .running),
      step(
        .assemble(AssembleRequest(destination: Self.folder.appending(path: "out.mp4"))),
        .queued))

    let jobs = [subject]
    #expect(actions(for: jobs).deliveredFiles(in: [subject.id]).isEmpty)
  }

  /// Once the job actually delivers, `.assemble`'s own artifact is the one
  /// file that should show up — the general rule (`Job.deliveredFiles`)
  /// applied to the one step of a composite job that ever carries a real
  /// destination.
  @Test func aDeliveredCompositeJobRevealsExactlyTheAssembledFile() {
    let destination = Self.folder.appending(path: "out.mp4")
    let subject = job(
      step(.downloadVideo(VideoRequest(videoID: "1", quality: "", destination: nil))),
      step(.assemble(AssembleRequest(destination: destination)), artifact: destination))

    let jobs = [subject]
    #expect(actions(for: jobs).deliveredFiles(in: [subject.id]) == [destination])
  }
}
