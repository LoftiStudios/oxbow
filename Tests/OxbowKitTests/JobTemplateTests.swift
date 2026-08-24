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
  private var chat: ChatRequest { ChatRequest(videoID: "2844548319", format: .json) }
  private var render: RenderRequest { RenderRequest(destination: URL(filePath: "/tmp/c.mp4")) }

  @Test func singleVerbTemplatesProduceOneIndependentStep() {
    let job = makeJob(.video(video))
    #expect(job.steps.count == 1)
    #expect(job.steps[0].dependsOn == nil)
  }

  @Test func chatAndRenderMakesTheRenderDependOnTheChatDownload() {
    let job = makeJob(.chatAndRender(chat, render))
    #expect(job.steps.count == 2)
    #expect(job.steps[0].dependsOn == nil)
    #expect(job.steps[1].dependsOn == job.steps[0].id)
  }

  /// The case the explicit `dependsOn` field exists for: the render depends on
  /// step 2 (the chat), NOT step 1 (the video), and the video is independent.
  @Test func videoChatAndRenderMakesTheRenderDependOnTheChatNotTheVideo() {
    let job = makeJob(.videoChatAndRender(video, chat, render))
    #expect(job.steps.count == 3)
    #expect(job.steps[0].dependsOn == nil, "video download is independent")
    #expect(job.steps[1].dependsOn == nil, "chat download is independent")
    #expect(job.steps[2].dependsOn == job.steps[1].id, "render depends on the chat")
    #expect(job.steps[2].dependsOn != job.steps[0].id)
  }

  /// Upstream's `chatrender -i` parses JSON and nothing else. Accepting the
  /// caller's `.html` here meant a full chat download followed by a parse
  /// exception in the step that consumes it.
  @Test func aRenderPairingAlwaysDownloadsItsChatAsJson() {
    let html = ChatRequest(videoID: "2844548319", format: .html)
    let jobs = [
      makeJob(.chatAndRender(html, render)),
      makeJob(.videoChatAndRender(video, html, render)),
    ]

    for job in jobs {
      let formats = job.steps.compactMap { step -> ChatFormat? in
        guard case .downloadChat(let request) = step.kind else { return nil }
        return request.format
      }
      #expect(formats == [.json])
    }
  }

  /// A standalone chat job is the user's own file, so their format stands.
  @Test func aStandaloneChatJobKeepsTheRequestedFormat() {
    let job = makeJob(.chat(ChatRequest(videoID: "2844548319", format: .html)))
    guard case .downloadChat(let request) = job.steps[0].kind else {
      Issue.record("expected a chat download step")
      return
    }
    #expect(request.format == .html)
  }

  @Test func everyNewStepStartsQueued() {
    let job = makeJob(.videoChatAndRender(video, chat, render))
    #expect(job.steps.allSatisfy { $0.status == .queued })
  }
}
