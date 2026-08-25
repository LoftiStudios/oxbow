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

  /// Get Info has to answer "which video is this?" and the queue never stored
  /// the link — only the id inside the request. Rebuilding the address is what
  /// makes the answer something you can paste back into a browser.
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

  /// A render-only job has no media step at all, so the only record of what it
  /// was rendering is the chat request's id. All-digits means a VOD — the same
  /// test upstream's `InfoHandler` branches on.
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

  /// Which outputs were asked for is the first thing Get Info should say, and
  /// the chat format is part of the answer — a JSON chat and an HTML one are
  /// not the same request.
  @Test func listsTheOutputsThatWereRequested() {
    let subject = job(
      step(.downloadVideo(videoRequest())),
      step(.downloadChat(ChatRequest(
        videoID: "1", format: .html,
        destination: Self.folder.appending(path: "a - chat.html")))),
      step(.renderChat(RenderRequest(destination: Self.folder.appending(path: "r.mp4")))))

    #expect(JobInfo(job: subject).outputs == ["Video", "Chat (HTML)", "Rendered chat"])
  }

  /// A chat step with no destination was downloaded only to be rendered and
  /// then discarded (`JobTemplate.renderInput`). Listing it as an output would
  /// promise a file that was never delivered.
  @Test func omitsAChatFileThatWasOnlyRenderInput() {
    let subject = job(
      step(.downloadChat(ChatRequest(videoID: "1", format: .json, destination: nil))),
      step(.renderChat(RenderRequest(destination: Self.folder.appending(path: "r.mp4")))))

    #expect(JobInfo(job: subject).outputs == ["Rendered chat"])
  }

  // MARK: - Where it went

  @Test func readsTheDestinationFolderFromWhereTheOutputsWereSentR() {
    let info = JobInfo(job: job(step(.downloadVideo(videoRequest()))))
    #expect(info.destinationFolder?.path == Self.folder.path)
  }

  /// Only steps that actually delivered something. `Step.artifact` is nil
  /// until a step succeeds, and `Reconciler` clears it again for anything
  /// still inside our own workspace.
  @Test func listsOnlyTheFilesThatWereActuallyDelivered() {
    let delivered = Self.folder.appending(path: "a.mp4")
    let subject = job(
      step(.downloadVideo(videoRequest()), .done, artifact: delivered),
      step(.downloadChat(ChatRequest(videoID: "1", format: .json)), .queued))

    #expect(JobInfo(job: subject).deliveredFiles == [delivered])
  }

  // MARK: - Render settings

  /// The render options are the biggest thing a job remembers and the hardest
  /// to reconstruct from memory, which is most of the reason Get Info exists.
  @Test func summarisesTheRenderSettings() {
    let request = RenderRequest(
      width: 420, height: 800, framerate: 60, fontSize: 14, font: "Inter Embedded",
      bitrateMbps: 5,
      destination: Self.folder.appending(path: "r.mp4"))
    let rows = JobInfo(job: job(step(.renderChat(request)))).renderSettings

    #expect(rows.first { $0.label == "Size" }?.value == "420 × 800")
    #expect(rows.first { $0.label == "Frame rate" }?.value == "60 fps")
    #expect(rows.first { $0.label == "Font" }?.value == "Inter Embedded 14")
    #expect(rows.first { $0.label == "Bitrate" }?.value == "5 Mbps")
  }

  /// Emote sources are listed by which are on, not as four yes/no rows —
  /// "BTTV, 7TV" says more in less space than three lines of "Yes".
  @Test func namesTheEmoteSourcesThatWereEnabled() {
    let request = RenderRequest(
      isBTTVEnabled: true, isFFZEnabled: false, isSTVEnabled: true,
      destination: Self.folder.appending(path: "r.mp4"))
    let rows = JobInfo(job: job(step(.renderChat(request)))).renderSettings

    #expect(rows.first { $0.label == "Emotes" }?.value == "BTTV, 7TV")
  }

  @Test func saysWhenNoEmoteSourcesWereEnabled() {
    let request = RenderRequest(
      isBTTVEnabled: false, isFFZEnabled: false, isSTVEnabled: false,
      destination: Self.folder.appending(path: "r.mp4"))
    let rows = JobInfo(job: job(step(.renderChat(request)))).renderSettings

    #expect(rows.first { $0.label == "Emotes" }?.value == "None")
  }

  /// A job with no render step has nothing to say about rendering, and an
  /// empty section is better than a section of defaults nobody chose.
  @Test func hasNoRenderSettingsWithoutARenderStep() {
    let info = JobInfo(job: job(step(.downloadVideo(videoRequest()))))
    #expect(info.renderSettings.isEmpty)
  }
}
