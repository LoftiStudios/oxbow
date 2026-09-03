import Foundation
import Testing

@testable import OxbowKit

/// Direct tests for the chat-seek margin.
///
/// A chat render does not always run as long as its video — renders end at the
/// last message — so a composite's resume point can land past the end of the
/// render. Seeking there yields zero frames, `hstack` has no last frame to
/// repeat, and the piece comes out empty while FFmpeg exits 0. The margin
/// clamps the chat's seek to just inside the render's end. Its own comment in
/// `StepContextBuilder` records that a wrong margin is invisible, and until
/// this suite existed nothing that runs in normal CI constrained the value.
@Suite("StepContextBuilder chat seek")
struct StepContextBuilderTests {

  private struct Harness {
    let builder: StepContextBuilder
    let workspace: Workspace
    let job: JobID
  }

  private func makeHarness() -> Harness {
    let root = URL(filePath: NSTemporaryDirectory())
      .appending(path: "oxbow-scb-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let workspace = Workspace(root: root)
    let journal = TeardownJournal(workspace: workspace)
    let ledger = ResumeLedger(workspace: workspace, journal: journal)
    return Harness(
      builder: StepContextBuilder(
        workspace: workspace,
        ffmpegPath: URL(filePath: "/usr/bin/false"),
        ledger: ledger),
      workspace: workspace,
      job: JobID(rawValue: UUID()))
  }

  private func cleanUp(_ workspace: Workspace) {
    try? FileManager.default.removeItem(at: workspace.root)
  }

  /// Builds a composite step wired to a video and a chat render, with all the
  /// on-disk state a resume needs: a video artifact, a render artifact of a
  /// known duration, `pieceFrames` worth of retained pieces, and a matching
  /// source fingerprint.
  ///
  /// - Parameter renderIsChatRender: when false, the second dependency is a
  ///   chat *download* rather than a render, which is how the margin's
  ///   framerate-less fallback becomes reachable.
  private func makeComposite(
    _ h: Harness,
    renderSeconds: Int,
    renderFramerate: Int,
    pieceFrames: UInt32,
    compositeFramerate: Int,
    renderIsChatRender: Bool = true) throws -> (job: Job, step: Step)
  {
    let artifacts = try h.workspace.prepareArtifacts(job: h.job)

    let videoURL = artifacts.appending(path: "video.mp4")
    try Data(repeating: 0xAB, count: 4096).write(to: videoURL)
    let videoStep = Step(
      id: StepID(rawValue: UUID()),
      kind: .downloadVideo(VideoRequest(videoID: "v", quality: "best")),
      status: .done,
      artifact: videoURL)

    // A real box layout, because the builder reads this file's duration.
    let renderURL = artifacts.appending(path: "render.mp4")
    try FragmentBuilder
      .fileWithDuration(timescale: 1000, duration: UInt64(renderSeconds) * 1000)
      .write(to: renderURL)
    let secondStep = Step(
      id: StepID(rawValue: UUID()),
      kind: renderIsChatRender
        ? .renderChat(RenderRequest(framerate: renderFramerate))
        : .downloadChat(ChatRequest(videoID: "v", format: .json)),
      status: .done,
      artifact: renderURL)

    let duration = Duration.seconds(renderSeconds * 2)
    let compositeStep = Step(
      id: StepID(rawValue: UUID()),
      kind: .composite(CompositeRequest(
        framerate: compositeFramerate,
        duration: duration,
        destination: h.workspace.root.appending(path: "out.mp4"))),
      dependsOn: [videoStep.id, secondStep.id])

    // One retained piece, so `resumePoint` reports a non-nil `from`.
    let resumeDirectory = try h.workspace.prepareResume(job: h.job)
    try FragmentBuilder.fragmentedFile([pieceFrames])
      .write(to: resumeDirectory.appending(path: "piece-0.mp4"))

    // A matching fingerprint, or the builder refuses to resume at all.
    try SourceFingerprint.of(videoURL, duration: duration)
      .write(to: resumeDirectory.appending(path: "source.json"))

    return (
      Job(id: h.job, created: .now, title: "t",
          steps: [videoStep, secondStep, compositeStep]),
      compositeStep)
  }

  /// The margin is two frames of the **render's** framerate, so a slower
  /// render lands the chat seek earlier.
  ///
  /// Framerates 4 and 16 rather than the realistic 30 and 60: `2.0 / fps` is
  /// exact in binary only for powers of two, so these are the rates whose
  /// expected landings can be written as independent literals instead of by
  /// re-deriving the production expression. The realistic pair is covered by
  /// the ordering test below.
  @Test func theChatSeekMarginIsTwoFramesOfTheRendersFramerate() throws {
    let slow = makeHarness()
    defer { cleanUp(slow.workspace) }
    let (slowJob, slowStep) = try makeComposite(
      slow, renderSeconds: 10, renderFramerate: 4,
      pieceFrames: 600, compositeFramerate: 30)
    let slowContext = try slow.builder.make(job: slowJob, step: slowStep)
    #expect(
      slowContext.chatResumeFrom == .seconds(9.5),
      "a 4fps render gives a 0.5s margin: 10 - 0.5")

    let fast = makeHarness()
    defer { cleanUp(fast.workspace) }
    let (fastJob, fastStep) = try makeComposite(
      fast, renderSeconds: 10, renderFramerate: 16,
      pieceFrames: 600, compositeFramerate: 30)
    let fastContext = try fast.builder.make(job: fastJob, step: fastStep)
    #expect(
      fastContext.chatResumeFrom == .seconds(9.875),
      "a 16fps render gives a 0.125s margin: 10 - 0.125")
  }

  /// The realistic pair, asserted by ordering because neither margin is exact
  /// in binary floating point.
  @Test func aSlowerRenderSeeksEarlierAtRealisticFramerates() throws {
    let thirty = makeHarness()
    defer { cleanUp(thirty.workspace) }
    let (j30, s30) = try makeComposite(
      thirty, renderSeconds: 10, renderFramerate: 30,
      pieceFrames: 600, compositeFramerate: 30)
    let at30 = try #require(try thirty.builder.make(job: j30, step: s30).chatResumeFrom)

    let sixty = makeHarness()
    defer { cleanUp(sixty.workspace) }
    let (j60, s60) = try makeComposite(
      sixty, renderSeconds: 10, renderFramerate: 60,
      pieceFrames: 600, compositeFramerate: 30)
    let at60 = try #require(try sixty.builder.make(job: j60, step: s60).chatResumeFrom)

    #expect(at30 < at60, "a 30fps render's two-frame margin is larger, so it lands earlier")
    #expect(at60 < .seconds(10), "both must land inside the render")
  }

  /// With no render framerate to read, the margin falls back to a quarter
  /// second. Reachable when the composite's second dependency is not a chat
  /// render — a defensive path rather than one `JobTemplate` builds today.
  @Test func withNoRenderFramerateTheMarginIsAQuarterSecond() throws {
    let h = makeHarness()
    defer { cleanUp(h.workspace) }
    let (job, step) = try makeComposite(
      h, renderSeconds: 10, renderFramerate: 30,
      pieceFrames: 600, compositeFramerate: 30, renderIsChatRender: false)

    let context = try h.builder.make(job: job, step: step)
    #expect(context.chatResumeFrom == .seconds(9.75), "the fallback margin is 0.25s: 10 - 0.25")
  }

  /// A resume point comfortably inside the render needs no clamp — the chat
  /// seeks with the video, which is what `nil` means to `ArgumentBuilder`.
  ///
  /// This is a differential test: the second half reuses every fixture
  /// parameter except `pieceFrames`, moving only the resume point out past
  /// the landing. That is what makes the first `nil` attributable to
  /// `from > landing` specifically — an unreadable render header or a missing
  /// resume point would take both cases to `nil` together, not just this one.
  ///
  /// The leading `resumeFrom != nil` assertion is a positive control: `make`'s
  /// guard chain short-circuits on `resume.from == nil` before it ever reaches
  /// the `from > landing` comparison this test is meant to exercise, so
  /// without that control a broken harness producing no resume point at all
  /// would pass this test vacuously, for the wrong reason.
  @Test func aResumePointInsideTheRenderNeedsNoChatSeek() throws {
    let h = makeHarness()
    defer { cleanUp(h.workspace) }
    // 150 frames at 30fps is a 5s resume point, well before the 9.875s landing.
    let (job, step) = try makeComposite(
      h, renderSeconds: 10, renderFramerate: 16,
      pieceFrames: 150, compositeFramerate: 30)

    let context = try h.builder.make(job: job, step: step)
    #expect(
      context.resumeFrom != nil,
      "precondition: the harness must produce a resume point, or the nil below proves nothing")
    #expect(context.chatResumeFrom == nil, "no clamp is needed, so the chat seeks with the video")

    // The same arrangement with a resume point past the landing must produce a
    // seek. Sharing every parameter but `pieceFrames` is what makes the nil
    // above attributable to `from > landing` rather than to any earlier leg of
    // the guard — an unreadable render header or a missing resume point would
    // take both cases to nil together.
    let past = makeHarness()
    defer { cleanUp(past.workspace) }
    let (pastJob, pastStep) = try makeComposite(
      past, renderSeconds: 10, renderFramerate: 16,
      pieceFrames: 600, compositeFramerate: 30)
    let pastContext = try past.builder.make(job: pastJob, step: pastStep)
    #expect(
      pastContext.chatResumeFrom == .seconds(9.875),
      "the identical fixture with a later resume point does clamp, so the nil above is the guard")
  }

  /// A render shorter than the margin would clamp to a negative timestamp.
  /// The guard returns nil instead.
  @Test func aRenderShorterThanTheMarginProducesNoChatSeek() throws {
    let h = makeHarness()
    defer { cleanUp(h.workspace) }
    // A 1s render at 4fps has a 0.5s margin; the resume point is past it.
    let (job, step) = try makeComposite(
      h, renderSeconds: 1, renderFramerate: 4,
      pieceFrames: 600, compositeFramerate: 30)

    let context = try h.builder.make(job: job, step: step)
    #expect(context.chatResumeFrom == .seconds(0.5), "a 1s render still clamps to 0.5s")

    // And with a margin larger than the render itself, there is nowhere to land.
    let tiny = makeHarness()
    defer { cleanUp(tiny.workspace) }
    let (tinyJob, tinyStep) = try makeComposite(
      tiny, renderSeconds: 1, renderFramerate: 1,
      pieceFrames: 600, compositeFramerate: 30)
    let tinyContext = try tiny.builder.make(job: tinyJob, step: tinyStep)
    #expect(
      tinyContext.chatResumeFrom == nil,
      "a 2s margin on a 1s render lands at or before zero, so there is no seek to make")
  }
}
