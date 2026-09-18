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
  /// Use a destination and non-JSON format so preservation and coercion are observable.
  private var chat: ChatRequest {
    ChatRequest(videoID: "2844548319", format: .html, destination: URL(filePath: "/tmp/chat.html"))
  }
  private var render: RenderRequest { RenderRequest(destination: URL(filePath: "/tmp/render.mp4")) }

  /// Composite fixture with media and implied chat/render plus assembly.
  private func compositeTemplate() -> JobTemplate {
    JobTemplate(
      media: .video(VideoRequest(videoID: "v", quality: "1080p60")),
      render: RenderRequest(),
      composite: CompositeRequest(
        framerate: 60, duration: .seconds(60),
        destination: URL(filePath: "/out/x.mp4")))
  }

  @Test func mediaOnlyProducesOneIndependentStep() {
    let job = makeJob(JobTemplate(media: .video(video)))
    #expect(job.steps.count == 1)
    #expect(job.steps[0].dependsOn.isEmpty)
    guard case .downloadVideo(let request) = job.steps[0].kind else {
      Issue.record("expected a video download step")
      return
    }
    #expect(request == video)
  }

  @Test func clipMediaProducesADownloadClipStep() {
    let job = makeJob(JobTemplate(media: .clip(clip)))
    #expect(job.steps.count == 1)
    #expect(job.steps[0].dependsOn.isEmpty)
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
    #expect(job.steps[0].dependsOn.isEmpty)
    guard case .downloadChat(let request) = job.steps[0].kind else {
      Issue.record("expected a chat download step")
      return
    }
    #expect(request.format == .html)
  }

  /// Render-only templates are unavailable in intake but public library calls still need a
  /// defined graph. With no media ID, only structure is meaningful here.
  @Test func renderOnlyImpliesAChatStepForcedToJsonWithNoDestination() {
    let job = makeJob(JobTemplate(render: render))
    #expect(job.steps.count == 2)
    #expect(job.steps[0].dependsOn.isEmpty)
    guard case .downloadChat(let request) = job.steps[0].kind else {
      Issue.record("expected the implied chat download to come first")
      return
    }
    #expect(request.format == .json)
    #expect(request.destination == nil)
    #expect(job.steps[1].dependsOn == [job.steps[0].id])
    guard case .renderChat = job.steps[1].kind else {
      Issue.record("expected the render step to come second")
      return
    }
  }

  @Test func chatAndRenderMakesTheRenderDependOnTheChatDownload() {
    let job = makeJob(JobTemplate(chat: chat, render: render))
    #expect(job.steps.count == 2)
    #expect(job.steps[0].dependsOn.isEmpty)
    #expect(job.steps[1].dependsOn == [job.steps[0].id])
    guard case .downloadChat(let request) = job.steps[0].kind else {
      Issue.record("expected a chat download step")
      return
    }
    #expect(request.videoID == chat.videoID)
    // Same folder and same base name — only the extension moves, to match the
    // format the pairing forced.
    #expect(request.destination?.deletingPathExtension()
      == chat.destination?.deletingPathExtension())
  }

  /// JSON coercion must also rewrite the delivery extension.
  @Test func aRenderPairingRewritesTheChatDestinationToMatchTheForcedFormat() {
    let job = makeJob(JobTemplate(chat: chat, render: render))
    guard case .downloadChat(let request) = job.steps[0].kind else {
      Issue.record("expected a chat download step")
      return
    }
    #expect(chat.destination?.pathExtension == "html", "the fixture must start out non-JSON")
    #expect(request.format == .json)
    #expect(request.destination == URL(filePath: "/tmp/chat.json"))
  }

  @Test func aRenderPairingLeavesAnAlreadyJsonChatDestinationAlone() {
    let jsonChat = ChatRequest(
      videoID: "2844548319", format: .json, destination: URL(filePath: "/tmp/chat.json"))
    let job = makeJob(JobTemplate(chat: jsonChat, render: render))
    guard case .downloadChat(let request) = job.steps[0].kind else {
      Issue.record("expected a chat download step")
      return
    }
    #expect(request.destination == jsonChat.destination)
  }

  /// A base name with a dot in it — a stream title like `v1.5 speedrun` —
  /// must lose only its real extension, not everything after the first dot.
  @Test func rewritingTheChatDestinationKeepsDotsInsideTheName() {
    let dottedChat = ChatRequest(
      videoID: "2844548319",
      format: .html,
      destination: URL(filePath: "/tmp/leighxp - v1.5 speedrun - chat.html"))
    let job = makeJob(JobTemplate(chat: dottedChat, render: render))
    guard case .downloadChat(let request) = job.steps[0].kind else {
      Issue.record("expected a chat download step")
      return
    }
    #expect(request.destination
      == URL(filePath: "/tmp/leighxp - v1.5 speedrun - chat.json"))
  }

  /// Chat off with render on: there is no delivered file, so there is no
  /// destination to rewrite and none to invent.
  @Test func aRenderPairingWithNoChatDeliveryStillHasNoDestination() {
    let job = makeJob(JobTemplate(render: render))
    guard case .downloadChat(let request) = job.steps[0].kind else {
      Issue.record("expected the implied chat download first")
      return
    }
    #expect(request.destination == nil)
  }

  /// The rewrite belongs to the render pairing alone. A chat job on its own
  /// keeps whatever the caller asked for, extension included.
  @Test func aChatDownloadWithNoRenderKeepsItsDestinationExactly() {
    let job = makeJob(JobTemplate(chat: chat))
    guard case .downloadChat(let request) = job.steps[0].kind else {
      Issue.record("expected a chat download step")
      return
    }
    #expect(request.format == .html)
    #expect(request.destination == chat.destination)
  }

  /// Video and standalone chat are independent network steps; template order still places chat
  /// first.
  @Test func mediaAndChatWithNoRenderAreTwoIndependentSteps() {
    let job = makeJob(JobTemplate(media: .video(video), chat: chat))
    #expect(job.steps.count == 2)
    #expect(job.steps[0].dependsOn.isEmpty)
    #expect(job.steps[1].dependsOn.isEmpty)
    guard case .downloadChat(let request) = job.steps[0].kind else {
      Issue.record("expected the chat download to come first")
      return
    }
    guard case .downloadVideo = job.steps[1].kind else {
      Issue.record("expected the video download to come second")
      return
    }
    // HTML fixture distinguishes preservation from an already-JSON request.
    #expect(request.format == .html)
    #expect(request.destination == chat.destination)
  }

  /// Render must depend on implied chat, which inherits the media ID, not on media directly.
  @Test func mediaAndRenderWithNoChatDeliveryMakesTheRenderDependOnTheImpliedChatNotTheMedia() {
    let job = makeJob(JobTemplate(media: .video(video), render: render))
    #expect(job.steps.count == 3)

    guard case .downloadChat(let chatRequest) = job.steps[0].kind else {
      Issue.record("expected the implied chat download first")
      return
    }
    #expect(job.steps[0].dependsOn.isEmpty, "the implied chat download is independent of the video")
    #expect(chatRequest.videoID == video.videoID, "the implied chat should target the same VOD as the video")
    #expect(chatRequest.format == .json)
    #expect(chatRequest.destination == nil)

    guard case .renderChat = job.steps[1].kind else {
      Issue.record("expected the render second")
      return
    }
    #expect(job.steps[1].dependsOn == [job.steps[0].id], "render depends on the chat")

    guard case .downloadVideo = job.steps[2].kind else {
      Issue.record("expected the video download third")
      return
    }
    #expect(job.steps[2].dependsOn.isEmpty, "video download is independent")
    #expect(job.steps[1].dependsOn != [job.steps[2].id], "render must not depend on the video")
  }

  /// Implied chat inherits media trim to keep rendered output aligned.
  @Test func mediaAndRenderWithATrimmedVideoImpliesAChatWithTheSameTrim() {
    let trimmedVideo = VideoRequest(
      videoID: "2844548319",
      quality: "160p30",
      trimStart: .seconds(30),
      trimEnd: .seconds(90),
      destination: URL(filePath: "/tmp/v.mp4"))

    let job = makeJob(JobTemplate(media: .video(trimmedVideo), render: render))
    guard case .downloadChat(let chatRequest) = job.steps[0].kind else {
      Issue.record("expected the implied chat download first")
      return
    }
    #expect(chatRequest.trimStart == trimmedVideo.trimStart)
    #expect(chatRequest.trimEnd == trimmedVideo.trimEnd)
  }

  /// Explicit chat trim wins; use different ranges to detect accidental media inheritance.
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
    guard case .downloadChat(let chatRequest) = job.steps[0].kind else {
      Issue.record("expected the chat download first")
      return
    }
    #expect(chatRequest.trimStart == trimmedChat.trimStart)
    #expect(chatRequest.trimEnd == trimmedChat.trimEnd)
    #expect(chatRequest.trimStart != trimmedVideo.trimStart)
    #expect(chatRequest.trimEnd != trimmedVideo.trimEnd)
  }

  /// Clip render input must inherit the exact slug; any nonempty placeholder would still fetch
  /// the wrong chat.
  @Test func clipMediaAndRenderImpliesAChatSeededWithTheClipSlug() {
    let job = makeJob(JobTemplate(media: .clip(clip), render: render))
    #expect(job.steps.count == 3)
    guard case .downloadChat(let chatRequest) = job.steps[0].kind else {
      Issue.record("expected the implied chat download first")
      return
    }
    #expect(chatRequest.videoID == clip.clipSlug)
    #expect(chatRequest.format == .json)
    #expect(chatRequest.destination == nil)
    guard case .renderChat = job.steps[1].kind else {
      Issue.record("expected the render second")
      return
    }
    #expect(job.steps[1].dependsOn == [job.steps[0].id], "render depends on the chat")
    guard case .downloadClip = job.steps[2].kind else {
      Issue.record("expected the clip download third")
      return
    }
  }

  /// Clip plus standalone chat follows the same independent-step contract as video.
  @Test func clipMediaAndChatWithNoRenderAreTwoIndependentSteps() {
    let job = makeJob(JobTemplate(media: .clip(clip), chat: chat))
    #expect(job.steps.count == 2)
    #expect(job.steps[0].dependsOn.isEmpty)
    #expect(job.steps[1].dependsOn.isEmpty)
    guard case .downloadChat(let request) = job.steps[0].kind else {
      Issue.record("expected the chat download to come first")
      return
    }
    guard case .downloadClip = job.steps[1].kind else {
      Issue.record("expected the clip download to come second")
      return
    }
    #expect(request.format == .html)
    #expect(request.destination == chat.destination)
  }

  /// The renderer accepts JSON only.
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
    #expect(job.steps[0].dependsOn.isEmpty, "chat download is independent")
    #expect(job.steps[1].dependsOn == [job.steps[0].id], "render depends on the chat")
    #expect(job.steps[2].dependsOn.isEmpty, "video download is independent")
    #expect(job.steps[1].dependsOn != [job.steps[2].id])

    guard case .downloadChat(let request) = job.steps[0].kind else {
      Issue.record("expected the chat download first")
      return
    }
    // The HTML fixture makes coercion and extension rewriting observable.
    #expect(request.format == .json)
    #expect(request.destination == URL(filePath: "/tmp/chat.json"))
  }

  /// Public empty templates remain well-defined despite being unavailable in intake.
  @Test func emptyTemplateProducesAJobWithNoSteps() {
    let job = makeJob(JobTemplate())
    #expect(job.steps.isEmpty)
  }

  @Test func everyNewStepStartsQueued() {
    let job = makeJob(JobTemplate(media: .video(video), chat: chat, render: render))
    #expect(job.steps.allSatisfy { $0.status == .queued })
  }

  @Test func aCompositeDependsOnTheVideoThenTheRender() {
    let template = JobTemplate(
      media: .video(VideoRequest(videoID: "v", quality: "1080p60")),
      render: RenderRequest(),
      composite: CompositeRequest(
        framerate: 60, duration: .seconds(60),
        destination: URL(filePath: "/out/x.mp4")))

    var n = 0
    let job = template.makeJob(id: Build.jobID(1), title: "t", created: .init()) {
      n += 1
      return Build.stepID(n)
    }

    // Chat precedes media to claim the network slot first, allowing later render/video overlap.
    #expect(job.steps.count == 5)
    let composite = job.steps[3]
    guard case .composite = composite.kind else {
      Issue.record("last step is not the composite")
      return
    }
    guard let mediaStep = job.steps.first(where: {
      if case .downloadVideo = $0.kind { return true }
      return false
    }) else {
      Issue.record("expected a video download step")
      return
    }
    guard let renderStep = job.steps.first(where: {
      if case .renderChat = $0.kind { return true }
      return false
    }) else {
      Issue.record("expected a render step")
      return
    }
    // Composite dependency order is video, then rendered chat; identify parents by kind after
    // step reordering.
    #expect(composite.dependsOn == [mediaStep.id, renderStep.id])
  }

  /// A composite implies the render it stacks, exactly as a render already
  /// implies the chat download it reads. Asking for one is enough.
  @Test func aCompositeImpliesTheRenderItStacks() {
    let template = JobTemplate(
      media: .video(VideoRequest(videoID: "v", quality: "1080p60")),
      composite: CompositeRequest(
        framerate: 60, duration: .seconds(60),
        destination: URL(filePath: "/out/x.mp4")))

    var n = 0
    let job = template.makeJob(id: Build.jobID(1), title: "t", created: .init()) {
      n += 1
      return Build.stepID(n)
    }

    // chat, render, video, composite, assemble.
    #expect(job.steps.count == 5)
    let composite = job.steps[3]
    guard case .composite = composite.kind else {
      Issue.record("expected the composite fourth")
      return
    }
    guard let mediaStep = job.steps.first(where: {
      if case .downloadVideo = $0.kind { return true }
      return false
    }) else {
      Issue.record("expected a video download step")
      return
    }
    guard let renderStep = job.steps.first(where: {
      if case .renderChat = $0.kind { return true }
      return false
    }) else {
      Issue.record("expected a render step")
      return
    }
    #expect(composite.dependsOn == [mediaStep.id, renderStep.id])
  }

  /// The one case that genuinely cannot be built: media is the input a
  /// composite cannot manufacture for itself.
  @Test func aCompositeWithNoMediaIsNotBuilt() {
    let template = JobTemplate(
      composite: CompositeRequest(
        framerate: 60, duration: .seconds(60),
        destination: URL(filePath: "/out/x.mp4")))

    var n = 0
    let job = template.makeJob(id: Build.jobID(1), title: "t", created: .init()) {
      n += 1
      return Build.stepID(n)
    }

    #expect(!job.steps.contains { if case .composite = $0.kind { true } else { false } })
  }

  /// After chat completes, scheduler must admit render and video together, proving the intended
  /// overlap rather than just array order.
  @Test func chatDoneMakesRenderAndMediaBothAdmissibleTogether() {
    let template = JobTemplate(
      media: .video(video),
      render: render,
      composite: CompositeRequest(
        framerate: 60, duration: .seconds(60),
        destination: URL(filePath: "/out/x.mp4")))
    var job = makeJob(template)

    guard let chatIndex = job.steps.firstIndex(where: {
      if case .downloadChat = $0.kind { return true }
      return false
    }) else {
      Issue.record("expected a chat download step")
      return
    }
    job.steps[chatIndex].status = .done

    guard let renderStep = job.steps.first(where: {
      if case .renderChat = $0.kind { return true }
      return false
    }) else {
      Issue.record("expected a render step")
      return
    }
    guard let mediaStep = job.steps.first(where: {
      if case .downloadVideo = $0.kind { return true }
      return false
    }) else {
      Issue.record("expected a video download step")
      return
    }

    let admitted = Scheduler.admissible(jobs: [job], running: [])
    #expect(Set(admitted) == Set([renderStep.id, mediaStep.id]))
  }

  /// Assembly depends only on composite retention; the downloaded source is removed before it
  /// runs.
  @Test func aCompositeJobEndsWithAnAssembleStep() throws {
    let job = compositeTemplate().makeJob(
      id: Build.jobID(1), title: "t", created: .now, nextStepID: Build.sequentialStepIDs())

    let assemble = try #require(job.steps.last)
    guard case .assemble = assemble.kind else {
      Issue.record("last step is \(assemble.kind), expected .assemble")
      return
    }
    let composite = try #require(job.steps.first { if case .composite = $0.kind { true } else { false } })
    // The composite alone. Assemble's audio comes from the sidecar in the
    // retention area, not from the downloaded video. resume.md §6.
    #expect(assemble.dependsOn == [composite.id])
  }

  /// A video-only job has nothing to assemble.
  @Test func aVideoOnlyJobHasNoAssembleStep() {
    let job = JobTemplate(media: .video(VideoRequest(videoID: "1", quality: "", destination: nil)))
      .makeJob(id: Build.jobID(1), title: "t", created: .now, nextStepID: Build.sequentialStepIDs())

    #expect(!job.steps.contains { if case .assemble = $0.kind { true } else { false } })
  }
}
