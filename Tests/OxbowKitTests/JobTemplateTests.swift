import Foundation
import Testing
@testable import OxbowKit

@Suite("Job templates")
struct JobTemplateTests {

  /// Deterministic ID generator so assertions can name specific steps.
  private func idGenerator() -> () -> StepID {
    var n = 0
    return {
      n += 1
      return StepID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-\(String(format: "%012d", n))")!)
    }
  }

  private func makeJob(_ template: JobTemplate) -> Job {
    template.makeJob(
      id: JobID(rawValue: UUID()),
      title: "t",
      created: Date(timeIntervalSince1970: 0),
      nextStepID: idGenerator())
  }

  private var video: VideoRequest {
    VideoRequest(videoID: "2844548319", quality: "160p30", destination: URL(filePath: "/tmp/v.mp4"))
  }
  private var clip: ClipRequest {
    ClipRequest(clipSlug: "AwkwardHelplessSalamanderSwiftRage", quality: "720p", destination: URL(filePath: "/tmp/c.mp4"))
  }
  /// Carries a destination so tests can distinguish "preserved" from
  /// "coincidentally nil", and a non-JSON format so a forced-to-JSON step can
  /// be told apart from one that merely started out that way.
  private var chat: ChatRequest {
    ChatRequest(videoID: "2844548319", format: .html, destination: URL(filePath: "/tmp/chat.html"))
  }
  private var render: RenderRequest { RenderRequest(destination: URL(filePath: "/tmp/render.mp4")) }

  @Test func mediaOnlyProducesOneIndependentStep() {
    let job = makeJob(JobTemplate(media: .video(video)))
    #expect(job.steps.count == 1)
    #expect(job.steps[0].dependsOn == nil)
    guard case .downloadVideo(let request) = job.steps[0].kind else {
      Issue.record("expected a video download step")
      return
    }
    #expect(request == video)
  }

  @Test func clipMediaProducesADownloadClipStep() {
    let job = makeJob(JobTemplate(media: .clip(clip)))
    #expect(job.steps.count == 1)
    #expect(job.steps[0].dependsOn == nil)
    guard case .downloadClip(let request) = job.steps[0].kind else {
      Issue.record("expected a clip download step")
      return
    }
    #expect(request == clip)
  }

  @Test func chatOnlyKeepsTheRequestedFormatAndIsIndependent() {
    let html = ChatRequest(videoID: "2844548319", format: .html)
    let job = makeJob(JobTemplate(chat: html))
    #expect(job.steps.count == 1)
    #expect(job.steps[0].dependsOn == nil)
    guard case .downloadChat(let request) = job.steps[0].kind else {
      Issue.record("expected a chat download step")
      return
    }
    #expect(request.format == .html)
  }

  /// The combination the design spec calls out as unrepresentable at real
  /// intake — Render's toggle always implies chat as an input there — but
  /// `makeJob` still has to produce something well-defined for it rather than
  /// crash or silently drop the render. There is no VOD ID anywhere in this
  /// template to seed the implied download with, so its content is a nil
  /// placeholder; only the structure (step count, forced format, forced-nil
  /// destination, dependency wiring) is meaningful here.
  @Test func renderOnlyImpliesAChatStepForcedToJsonWithNoDestination() {
    let job = makeJob(JobTemplate(render: render))
    #expect(job.steps.count == 2)
    #expect(job.steps[0].dependsOn == nil)
    guard case .downloadChat(let request) = job.steps[0].kind else {
      Issue.record("expected the implied chat download to come first")
      return
    }
    #expect(request.format == .json)
    #expect(request.destination == nil)
    #expect(job.steps[1].dependsOn == job.steps[0].id)
    guard case .renderChat = job.steps[1].kind else {
      Issue.record("expected the render step to come second")
      return
    }
  }

  @Test func chatAndRenderMakesTheRenderDependOnTheChatDownloadAndKeepsTheDestination() {
    let job = makeJob(JobTemplate(chat: chat, render: render))
    #expect(job.steps.count == 2)
    #expect(job.steps[0].dependsOn == nil)
    #expect(job.steps[1].dependsOn == job.steps[0].id)
    guard case .downloadChat(let request) = job.steps[0].kind else {
      Issue.record("expected a chat download step")
      return
    }
    #expect(request.destination == chat.destination)
    #expect(request.videoID == chat.videoID)
  }

  /// The combination the enum could not express at all: video plus chat, but
  /// no render pairing to force a dependency between them.
  @Test func mediaAndChatWithNoRenderAreTwoIndependentSteps() {
    let job = makeJob(JobTemplate(media: .video(video), chat: chat))
    #expect(job.steps.count == 2)
    #expect(job.steps[0].dependsOn == nil)
    #expect(job.steps[1].dependsOn == nil)
    guard case .downloadVideo = job.steps[0].kind else {
      Issue.record("expected the video download to come first")
      return
    }
    guard case .downloadChat(let request) = job.steps[1].kind else {
      Issue.record("expected the chat download to come second")
      return
    }
    // Unlike the render pairing, a standalone chat delivery keeps the
    // caller's requested format untouched. `chat`'s fixture format is `.html`
    // specifically so this can tell "preserved" apart from "coincidentally
    // already JSON".
    #expect(request.format == .html)
    #expect(request.destination == chat.destination)
  }

  /// The case the explicit `dependsOn` field exists for: with no chat
  /// requested, the render must still depend on the *implied* chat step
  /// (step 2), never on the media step (step 1). The implied chat borrows the
  /// video's own ID — a plausible-but-wrong implementation would instead
  /// synthesise a chat request with no VOD ID at all, which would fetch
  /// nothing useful even though the VOD ID was sitting right there in the
  /// media request.
  @Test func mediaAndRenderWithNoChatDeliveryMakesTheRenderDependOnTheImpliedChatNotTheMedia() {
    let job = makeJob(JobTemplate(media: .video(video), render: render))
    #expect(job.steps.count == 3)
    #expect(job.steps[0].dependsOn == nil, "video download is independent")

    guard case .downloadVideo = job.steps[0].kind else {
      Issue.record("expected the video download first")
      return
    }
    guard case .downloadChat(let chatRequest) = job.steps[1].kind else {
      Issue.record("expected the implied chat download second")
      return
    }
    #expect(job.steps[1].dependsOn == nil, "the implied chat download is independent of the video")
    #expect(chatRequest.videoID == video.videoID, "the implied chat should target the same VOD as the video")
    #expect(chatRequest.format == .json)
    #expect(chatRequest.destination == nil)

    #expect(job.steps[2].dependsOn == job.steps[1].id, "render depends on the chat")
    #expect(job.steps[2].dependsOn != job.steps[0].id, "render must not depend on the video")
  }

  /// A trimmed video must not get chat rendered against the full VOD: the
  /// implied chat download has to carry the same trim range as the video
  /// it is paired with, or the render's output would silently desync from
  /// what the user actually asked to trim.
  @Test func mediaAndRenderWithATrimmedVideoImpliesAChatWithTheSameTrim() {
    let trimmedVideo = VideoRequest(
      videoID: "2844548319",
      quality: "160p30",
      trimStart: .seconds(30),
      trimEnd: .seconds(90),
      destination: URL(filePath: "/tmp/v.mp4"))

    let job = makeJob(JobTemplate(media: .video(trimmedVideo), render: render))
    guard case .downloadChat(let chatRequest) = job.steps[1].kind else {
      Issue.record("expected the implied chat download second")
      return
    }
    #expect(chatRequest.trimStart == trimmedVideo.trimStart)
    #expect(chatRequest.trimEnd == trimmedVideo.trimEnd)
  }

  /// Trim inheritance is for the *implied* chat only. When the caller
  /// supplies its own chat request, `chat ?? impliedChatRequest(for:)` must
  /// never overwrite the caller's trim with the media's — the two ranges
  /// are deliberately different here so an implementation that wrongly
  /// preferred the video's trim would fail this, rather than passing by
  /// coincidence.
  @Test func mediaChatAndRenderKeepTheExplicitChatsOwnTrimNotTheMedias() {
    let trimmedVideo = VideoRequest(
      videoID: "2844548319",
      quality: "160p30",
      trimStart: .seconds(30),
      trimEnd: .seconds(90),
      destination: URL(filePath: "/tmp/v.mp4"))
    let trimmedChat = ChatRequest(
      videoID: "2844548319",
      trimStart: .seconds(0),
      trimEnd: .seconds(10),
      format: .html)

    let job = makeJob(JobTemplate(media: .video(trimmedVideo), chat: trimmedChat, render: render))
    guard case .downloadChat(let chatRequest) = job.steps[1].kind else {
      Issue.record("expected the chat download second")
      return
    }
    #expect(chatRequest.trimStart == trimmedChat.trimStart)
    #expect(chatRequest.trimEnd == trimmedChat.trimEnd)
    #expect(chatRequest.trimStart != trimmedVideo.trimStart)
    #expect(chatRequest.trimEnd != trimmedVideo.trimEnd)
  }

  /// Clips are a media type the enum could not add without doubling its case
  /// count (`clipAndChat`, `clipChatAndRender`). This is the render half: the
  /// implied chat download has no video to borrow a VOD ID from, so it must
  /// seed itself with the clip's own slug — upstream's `chatdownload --id`
  /// accepts either. Asserting the exact slug, not merely "non-empty", is
  /// deliberate: a wrong implementation could satisfy "non-empty" with any
  /// placeholder and still fetch nothing.
  @Test func clipMediaAndRenderImpliesAChatSeededWithTheClipSlug() {
    let job = makeJob(JobTemplate(media: .clip(clip), render: render))
    #expect(job.steps.count == 3)
    guard case .downloadClip = job.steps[0].kind else {
      Issue.record("expected the clip download first")
      return
    }
    guard case .downloadChat(let chatRequest) = job.steps[1].kind else {
      Issue.record("expected the implied chat download second")
      return
    }
    #expect(chatRequest.videoID == clip.clipSlug)
    #expect(chatRequest.format == .json)
    #expect(chatRequest.destination == nil)
    #expect(job.steps[2].dependsOn == job.steps[1].id, "render depends on the chat")
  }

  /// The clip counterpart to `mediaAndChatWithNoRenderAreTwoIndependentSteps`:
  /// `.clip` media works the same as `.video` in the media+chat, no-render
  /// combination — two independent steps, the caller's own chat request
  /// untouched.
  @Test func clipMediaAndChatWithNoRenderAreTwoIndependentSteps() {
    let job = makeJob(JobTemplate(media: .clip(clip), chat: chat))
    #expect(job.steps.count == 2)
    #expect(job.steps[0].dependsOn == nil)
    #expect(job.steps[1].dependsOn == nil)
    guard case .downloadClip = job.steps[0].kind else {
      Issue.record("expected the clip download to come first")
      return
    }
    guard case .downloadChat(let request) = job.steps[1].kind else {
      Issue.record("expected the chat download to come second")
      return
    }
    #expect(request.format == .html)
    #expect(request.destination == chat.destination)
  }

  /// Upstream's `chatrender -i` parses JSON and nothing else. Accepting the
  /// caller's `.html` here meant a full chat download followed by a parse
  /// exception in the step that consumes it.
  @Test func aRenderPairingAlwaysDownloadsItsChatAsJson() {
    let html = ChatRequest(videoID: "2844548319", format: .html)
    let jobs = [
      makeJob(JobTemplate(chat: html, render: render)),
      makeJob(JobTemplate(media: .video(video), chat: html, render: render)),
    ]

    for job in jobs {
      let formats = job.steps.compactMap { step -> ChatFormat? in
        guard case .downloadChat(let request) = step.kind else { return nil }
        return request.format
      }
      #expect(formats == [.json])
    }
  }

  @Test func mediaChatAndRenderShareTheSameDependencyStructure() {
    let job = makeJob(JobTemplate(media: .video(video), chat: chat, render: render))
    #expect(job.steps.count == 3)
    #expect(job.steps[0].dependsOn == nil, "video download is independent")
    #expect(job.steps[1].dependsOn == nil, "chat download is independent")
    #expect(job.steps[2].dependsOn == job.steps[1].id, "render depends on the chat")
    #expect(job.steps[2].dependsOn != job.steps[0].id)

    guard case .downloadChat(let request) = job.steps[1].kind else {
      Issue.record("expected the chat download second")
      return
    }
    // The render pairing forces JSON — `chat`'s fixture format is `.html`, so
    // this genuinely exercises the override rather than coinciding with it —
    // but does not touch the destination the caller already asked for.
    #expect(request.format == .json)
    #expect(request.destination == chat.destination)
  }

  /// Documented rather than merely permitted: intake makes this unreachable
  /// (Add is disabled with no outputs selected), but `makeJob` still needs
  /// well-defined behaviour for the fully-empty template rather than a crash.
  @Test func emptyTemplateProducesAJobWithNoSteps() {
    let job = makeJob(JobTemplate())
    #expect(job.steps.isEmpty)
  }

  @Test func everyNewStepStartsQueued() {
    let job = makeJob(JobTemplate(media: .video(video), chat: chat, render: render))
    #expect(job.steps.allSatisfy { $0.status == .queued })
  }
}
