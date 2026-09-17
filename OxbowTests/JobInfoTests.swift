import Foundation
import Testing
import OxbowKit
@testable import Oxbow

@Suite("Job info")
struct JobInfoTests {

  // MARK: - Fixtures

  private static let folder = URL(filePath: "/Users/someone/Downloads")

  private func step(_ kind: StepKind, _ status: StepStatus = .done, artifact: URL? = nil) -> Step {
    Step(id: StepID(rawValue: UUID()), kind: kind, status: status, artifact: artifact)
  }

  private func job(_ steps: Step...) -> Job {
    Job(id: JobID(rawValue: UUID()), created: .now, title: "t", steps: steps)
  }

  private func videoRequest(
    quality: String = "",
    trimStart: Duration? = nil,
    trimEnd: Duration? = nil)
    -> VideoRequest
  {
    VideoRequest(
      videoID: "2844548319",
      quality: quality,
      trimStart: trimStart,
      trimEnd: trimEnd,
      destination: Self.folder.appending(path: "a.mp4"))
  }

  // MARK: - Where it came from

  /// Reconstruct source URLs from request IDs because the original pasted link is not stored.
  @Test func rebuildsTheSourceURLOfAVODFromItsID() {
    let info = JobInfo(job: job(step(.downloadVideo(videoRequest()))))
    #expect(info.sourceURL?.absoluteString == "https://www.twitch.tv/videos/2844548319")
  }

  @Test func rebuildsTheSourceURLOfAClipFromItsSlug() {
    let request = ClipRequest(
      clipSlug: "TangibleGiantPancakeKappa",
      quality: "",
      destination: Self.folder.appending(path: "a.mp4"))
    let info = JobInfo(job: job(step(.downloadClip(request))))
    #expect(
      info.sourceURL?.absoluteString
        == "https://clips.twitch.tv/TangibleGiantPancakeKappa")
  }

  /// Render-only jobs identify their source through chat; numeric IDs denote VODs.
  @Test func fallsBackToTheChatRequestsIDWhenThereIsNoMediaStep() {
    let chat = ChatRequest(videoID: "2844548319", format: .json)
    let info = JobInfo(job: job(step(.downloadChat(chat))))
    #expect(info.sourceURL?.absoluteString == "https://www.twitch.tv/videos/2844548319")
  }

  @Test func readsANonNumericChatIDAsAClipSlug() {
    let chat = ChatRequest(videoID: "TangibleGiantPancakeKappa", format: .json)
    let info = JobInfo(job: job(step(.downloadChat(chat))))
    #expect(
      info.sourceURL?.absoluteString
        == "https://clips.twitch.tv/TangibleGiantPancakeKappa")
  }

  // MARK: - Settings

  /// An empty quality is not a missing value — it is the choice that means
  /// "let the CLI pick source", and it has to read as one.
  @Test func describesAnEmptyQualityAsBestAvailable() {
    let info = JobInfo(job: job(step(.downloadVideo(videoRequest()))))
    #expect(info.quality == "Best available")
  }

  @Test func describesAChosenQualityByName() {
    let info = JobInfo(job: job(step(.downloadVideo(videoRequest(quality: "1080p60")))))
    #expect(info.quality == "1080p60")
  }

  @Test func describesAnAbsentTrimAsTheWholeVideo() {
    let info = JobInfo(job: job(step(.downloadVideo(videoRequest()))))
    #expect(info.trim == "Whole video")
  }

  @Test func describesATrimAsARange() {
    let info = JobInfo(job: job(step(.downloadVideo(
      videoRequest(trimStart: .seconds(90), trimEnd: .seconds(4350))))))
    #expect(info.trim == "1:30 to 1:12:30")
  }

  /// A start with no end is a legal trim — everything from there on.
  @Test func describesAnOpenEndedTrim() {
    let info = JobInfo(job: job(step(.downloadVideo(videoRequest(trimStart: .seconds(90))))))
    #expect(info.trim == "From 1:30")
  }

  /// Requested outputs include the chat format.
  @Test func listsTheOutputsThatWereRequested() {
    let subject = job(
      step(.downloadVideo(videoRequest())),
      step(.downloadChat(ChatRequest(
        videoID: "1", format: .html,
        destination: Self.folder.appending(path: "a - chat.html")))),
      step(.renderChat(RenderRequest(destination: Self.folder.appending(path: "r.mp4")))))

    #expect(JobInfo(job: subject).outputs == ["Video", "Chat (HTML)", "Rendered chat"])
  }

  /// Chat without a destination is an intermediate, not a delivered output.
  @Test func omitsAChatFileThatWasOnlyRenderInput() {
    let subject = job(
      step(.downloadChat(ChatRequest(videoID: "1", format: .json, destination: nil))),
      step(.renderChat(RenderRequest(destination: Self.folder.appending(path: "r.mp4")))))

    #expect(JobInfo(job: subject).outputs == ["Rendered chat"])
  }

  /// A composite delivers only assembly output; its video, chat, and render are intermediates.
  @Test func reportsExactlyTheCompositeAsAnOutputOfACompositeJob() {
    let video = VideoRequest(videoID: "2844548319", quality: "1080p60", destination: nil)
    let subject = job(
      step(.downloadVideo(video)),
      step(.downloadChat(ChatRequest(videoID: "1", format: .json, destination: nil))),
      step(.renderChat(RenderRequest(destination: nil))),
      step(.composite(CompositeRequest(
        framerate: 60, duration: .seconds(60),
        destination: Self.folder.appending(path: "a.mp4")))))

    #expect(JobInfo(job: subject).outputs == ["Video + chat"])
  }

  // MARK: - Where it went

  @Test func readsTheDestinationFolderFromWhereTheOutputsWereSentR() {
    let info = JobInfo(job: job(step(.downloadVideo(videoRequest()))))
    #expect(info.destinationFolder?.path == Self.folder.path)
  }

  /// Only completed outputs with delivery destinations belong here.
  @Test func listsOnlyTheFilesThatWereActuallyDelivered() {
    let delivered = Self.folder.appending(path: "a.mp4")
    let subject = job(
      step(.downloadVideo(videoRequest()), .done, artifact: delivered),
      step(.downloadChat(ChatRequest(videoID: "1", format: .json)), .queued))

    #expect(JobInfo(job: subject).deliveredFiles == [delivered])
  }

  /// Retained pieces can survive failed/cancelled jobs outside the workspace, but are not
  /// delivered files. Only assembly output is delivered.
  @Test func excludesARetainedPieceEvenWhenTheCompositeStepStillClaimsOne() {
    let piece = URL(filePath: "/Caches/studio.lofti.Oxbow/resume/abc/piece-0.mp4")
    let composite = CompositeRequest(
      framerate: 60, duration: .seconds(60),
      destination: Self.folder.appending(path: "out.mp4"))
    let subject = job(
      step(
        .composite(composite),
        .failed(StepFailure(kind: .noArtifact, summary: "boom")),
        artifact: piece),
      step(.assemble(AssembleRequest(destination: Self.folder.appending(path: "out.mp4"))), .queued))

    #expect(JobInfo(job: subject).deliveredFiles.isEmpty)
  }

  // MARK: - Render settings

  /// Report composite chat geometry, not fixed renderer defaults the user never chose.
  @Test func reportsTheChatColumnGeometryOfAComposite() {
    let render = RenderRequest(width: 420, height: 800, framerate: 30, destination: nil)
    let composite = CompositeRequest(
      framerate: 60, duration: .seconds(60),
      destination: Self.folder.appending(path: "a.mp4"))
    let rows = JobInfo(job: job(step(.renderChat(render)), step(.composite(composite)))).renderSettings

    #expect(rows == [JobInfo.Setting(label: "Chat column", value: "420 × 800 at 30 fps")])
  }

  /// A standalone library render has no video-relative chat geometry to report.
  @Test func hasNoRenderSettingsWithoutACompositeStep() {
    let request = RenderRequest(destination: Self.folder.appending(path: "r.mp4"))
    let info = JobInfo(job: job(step(.renderChat(request))))
    #expect(info.renderSettings.isEmpty)
  }

  /// A job with no render step has nothing to say about rendering, and an
  /// empty section is better than a section of defaults nobody chose.
  @Test func hasNoRenderSettingsWithoutARenderStep() {
    let info = JobInfo(job: job(step(.downloadVideo(videoRequest()))))
    #expect(info.renderSettings.isEmpty)
  }
}
