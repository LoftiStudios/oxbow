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

  /// Mirrors the construction the other composite tests use below — media,
  /// an implied render, and a composite, which is enough to build all four
  /// upstream steps plus the assemble step this file's tests are about.
  private func compositeTemplate() -> JobTemplate {
    JobTemplate(
      media: .video(VideoRequest(videoID: "v", quality: "1080p60")),
      render: RenderRequest(),
      composite: CompositeRequest(
        framerate: 60, bitrateMbps: 8, duration: .seconds(60),
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

  /// A render pairing forces the chat download to JSON, so the file it
  /// delivers has to be *named* JSON too. Leaving the caller's `.html` path
  /// alone wrote JSON bytes into a file called `chat.html` — the extension is
  /// the only thing telling the user, or Finder, what is actually in there.
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

  /// The combination the enum could not express at all: video plus chat, but
  /// no render pairing to force a dependency between them. Both are still
  /// `.network`, so nothing here depends on order — but `makeJob` always
  /// appends chat before media (see the load-bearing-order note in
  /// `makeJob`), so the chat step comes first regardless.
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
    guard case .downloadChat(let chatRequest) = job.steps[0].kind else {
      Issue.record("expected the implied chat download first")
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
    guard case .downloadChat(let chatRequest) = job.steps[0].kind else {
      Issue.record("expected the chat download first")
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

  /// The clip counterpart to `mediaAndChatWithNoRenderAreTwoIndependentSteps`:
  /// `.clip` media works the same as `.video` in the media+chat, no-render
  /// combination — two independent steps, the caller's own chat request
  /// untouched.
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
    #expect(job.steps[0].dependsOn.isEmpty, "chat download is independent")
    #expect(job.steps[1].dependsOn == [job.steps[0].id], "render depends on the chat")
    #expect(job.steps[2].dependsOn.isEmpty, "video download is independent")
    #expect(job.steps[1].dependsOn != [job.steps[2].id])

    guard case .downloadChat(let request) = job.steps[0].kind else {
      Issue.record("expected the chat download first")
      return
    }
    // The render pairing forces JSON — `chat`'s fixture format is `.html`, so
    // this genuinely exercises the override rather than coinciding with it —
    // and the destination follows the format rather than staying `.html`.
    #expect(request.format == .json)
    #expect(request.destination == URL(filePath: "/tmp/chat.json"))
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

  @Test func aCompositeDependsOnTheVideoThenTheRender() {
    let template = JobTemplate(
      media: .video(VideoRequest(videoID: "v", quality: "1080p60")),
      render: RenderRequest(),
      composite: CompositeRequest(
        framerate: 60, bitrateMbps: 8, duration: .seconds(60),
        destination: URL(filePath: "/out/x.mp4")))

    var n = 0
    let job = template.makeJob(id: Build.jobID(1), title: "t", created: .init()) {
      n += 1
      return Build.stepID(n)
    }

    // chat, render, video, composite, assemble — chat and render are
    // appended before the media step so the short chat download claims the
    // network slot first; see the load-bearing-order note in `makeJob`.
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
    // ORDER IS THE CONTRACT: ArgumentBuilder reads [0] as the video and [1]
    // as the chat render — identified by kind, not position, since the
    // reorder above moves media to a later index without changing which
    // step is which parent.
    #expect(composite.dependsOn == [mediaStep.id, renderStep.id])
  }

  /// A composite implies the render it stacks, exactly as a render already
  /// implies the chat download it reads. Asking for one is enough.
  @Test func aCompositeImpliesTheRenderItStacks() {
    let template = JobTemplate(
      media: .video(VideoRequest(videoID: "v", quality: "1080p60")),
      composite: CompositeRequest(
        framerate: 60, bitrateMbps: 8, duration: .seconds(60),
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
        framerate: 60, bitrateMbps: 8, duration: .seconds(60),
        destination: URL(filePath: "/out/x.mp4")))

    var n = 0
    let job = template.makeJob(id: Build.jobID(1), title: "t", created: .init()) {
      n += 1
      return Build.stepID(n)
    }

    #expect(!job.steps.contains { if case .composite = $0.kind { true } else { false } })
  }

  /// The behaviour the reorder in `makeJob` exists to buy, proved against
  /// `Scheduler` rather than merely against step indices: once the chat
  /// download is `.done`, the render (`.compute`) and the media download
  /// (`.network`) share no resource class, so `Scheduler.admissible` must
  /// admit both in the same call rather than making one wait behind the
  /// other. See docs/design/compositing.md §6 for the timeline this buys.
  @Test func chatDoneMakesRenderAndMediaBothAdmissibleTogether() {
    let template = JobTemplate(
      media: .video(video),
      render: render,
      composite: CompositeRequest(
        framerate: 60, bitrateMbps: 8, duration: .seconds(60),
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

  /// Assemble depends on the composite step alone. The audio it maps comes
  /// from the sidecar the composite's first attempt copies into the
  /// retention area, not from the downloaded video — so by the time assemble
  /// runs, the media step's own output has already been deleted (§5) and
  /// cannot be a dependency. docs/design/resume.md §6.
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
