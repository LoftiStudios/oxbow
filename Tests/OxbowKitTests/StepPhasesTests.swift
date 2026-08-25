import Foundation
import Testing
@testable import OxbowKit

@Suite("Step phases")
struct StepPhasesTests {

  private func video(_ quality: String = "") -> StepKind {
    .downloadVideo(VideoRequest(
      videoID: "1", quality: quality, destination: URL(filePath: "/tmp/a.mp4")))
  }

  private func chat(embeddingImages: Bool = false) -> StepKind {
    .downloadChat(ChatRequest(
      videoID: "1", format: .json, isEmbeddingImages: embeddingImages,
      destination: URL(filePath: "/tmp/a.json")))
  }

  private var render: StepKind {
    .renderChat(RenderRequest(destination: URL(filePath: "/tmp/a.mp4")))
  }

  private var clip: StepKind {
    .downloadClip(ClipRequest(
      clipSlug: "s", quality: "", destination: URL(filePath: "/tmp/a.mp4")))
  }

  private func progress(_ phase: String?, index: Int? = nil, total: Int? = nil) -> StepProgress {
    StepProgress(phase: phase, index: index, total: total)
  }

  // MARK: - What each verb goes through

  @Test func namesTheFourPhasesOfAVideoDownload() {
    let phases = StepPhases.expected(for: video())
    #expect(phases?.phases.map(\.cliName)
      == ["Fetching Video Info", "Downloading", "Verifying Parts", "Finalizing Video"])
  }

  @Test func namesTheTwoPhasesOfAClipDownload() {
    #expect(StepPhases.expected(for: clip)?.phases.map(\.cliName)
      == ["Fetching Clip Info", "Downloading Clip"])
  }

  @Test func namesTheTwoPhasesOfAChatRender() {
    #expect(StepPhases.expected(for: render)?.phases.map(\.cliName)
      == ["Fetching Images", "Rendering Video"])
  }

  /// `ChatDownloader` only emits "Downloading Embed Images" when it was asked
  /// to embed them, so a bar with a fixed fourth segment would leave a gap
  /// that never fills on every chat download that does not.
  @Test func aChatDownloadGainsAnImagePhaseOnlyWhenEmbeddingImages() {
    #expect(StepPhases.expected(for: chat())?.phases.map(\.cliName)
      == ["Downloading", "Backfilling Commenter Info", "Writing Output File"])

    #expect(StepPhases.expected(for: chat(embeddingImages: true))?.phases.map(\.cliName)
      == ["Downloading", "Downloading Embed Images", "Backfilling Commenter Info",
          "Writing Output File"])
  }

  // MARK: - Placing an observed phase

  @Test func placesAPhaseByItsName() {
    let phases = StepPhases.expected(for: video())
    #expect(phases?.index(matching: progress("Verifying Parts", index: 3, total: 4)) == 2)
  }

  /// The case this whole approach exists for. The renderer announces
  /// `Fetching Images [1/2]` and then drops the counter entirely for
  /// `Rendering Video` — which is the phase that takes all the time — so a bar
  /// driven off the counter alone would stall on segment one and never move.
  @Test func placesARenderersSecondPhaseEvenThoughTheCounterIsGone() {
    let phases = StepPhases.expected(for: render)
    #expect(phases?.index(matching: progress("Rendering Video")) == 1)
  }

  /// `ChatDownloader` emits no counter at all, on any phase.
  @Test func placesAChatDownloadsPhasesWithNoCounterAnywhere() {
    let phases = StepPhases.expected(for: chat())
    #expect(phases?.index(matching: progress("Downloading")) == 0)
    #expect(phases?.index(matching: progress("Backfilling Commenter Info")) == 1)
    #expect(phases?.index(matching: progress("Writing Output File")) == 2)
  }

  /// Upstream could restyle a phase name at any time. When that happens the
  /// counter is the fallback, so a bar degrades to "we know where we are but
  /// not what it is called" rather than to nothing.
  @Test func fallsBackToTheCounterWhenTheNameIsUnrecognised() {
    let phases = StepPhases.expected(for: video())
    #expect(phases?.index(matching: progress("Reticulating Splines", index: 3, total: 4)) == 2)
  }

  /// But only when the counter agrees about how many phases there are.
  /// `TsMerger` emits its own `[1/2]` sequence with a "Verifying Parts" name
  /// that also appears in the four-phase video flow; a mismatched total means
  /// we are not looking at the sequence we think we are.
  @Test func refusesTheCounterWhenItDisagreesAboutTheNumberOfPhases() {
    let phases = StepPhases.expected(for: video())
    #expect(phases?.index(matching: progress("Reticulating Splines", index: 1, total: 2)) == nil)
  }

  @Test func placesNothingWithNeitherANameNorACounter() {
    #expect(StepPhases.expected(for: video())?.index(matching: progress(nil)) == nil)
  }

  // MARK: - Against the real captured output

  /// Replays a real captured run through the parser and asserts every status
  /// line it produces lands somewhere.
  ///
  /// This is the test that earns the hardcoded phase names: it fails the day
  /// upstream renames one and the fixtures are recaptured, which is exactly
  /// when a segmented bar would otherwise start silently stalling.
  @Test(arguments: [
    ("videodownload-success.stdout", 4),
    ("chatdownload-success.stdout", 3),
  ])
  func everyPhaseInACapturedRunIsRecognised(fixture: String, expectedPhases: Int) throws {
    let kind: StepKind = fixture.hasPrefix("video")
      ? .downloadVideo(VideoRequest(
        videoID: "1", quality: "", destination: URL(filePath: "/tmp/a.mp4")))
      : .downloadChat(ChatRequest(
        videoID: "1", format: .json, destination: URL(filePath: "/tmp/a.json")))

    let phases = try #require(StepPhases.expected(for: kind))
    #expect(phases.phases.count == expectedPhases)

    var parser = StatusLineParser()
    var lines = parser.consume(try Fixture.bytes(fixture))
    if let last = parser.finish() { lines.append(last) }

    let statuses = lines.compactMap { line -> StepProgress? in
      if case .status(let progress) = line { return progress }
      return nil
    }
    #expect(!statuses.isEmpty, "precondition: the fixture should contain status lines")

    var previous = -1
    for status in statuses {
      let index = try #require(
        phases.index(matching: status),
        "unplaced phase \(status.phase ?? "nil") — upstream may have renamed it")
      #expect(index >= previous, "phase \(status.phase ?? "nil") went backwards")
      previous = index
    }
  }

  /// The renderer's captured run, which the arguments above cannot cover
  /// because its second phase carries no counter and its first is the only one
  /// that does.
  @Test func everyPhaseInACapturedRenderIsRecognised() throws {
    let phases = try #require(StepPhases.expected(for: render))

    var parser = StatusLineParser()
    var lines = parser.consume(try Fixture.bytes("chatrender-success.stdout"))
    if let last = parser.finish() { lines.append(last) }

    let statuses = lines.compactMap { line -> StepProgress? in
      if case .status(let progress) = line { return progress }
      return nil
    }

    for status in statuses {
      #expect(
        phases.index(matching: status) != nil,
        "unplaced phase \(status.phase ?? "nil")")
    }
  }

  @Test func aCompositeIsOnePhaseThatSimplyFills() throws {
    let request = CompositeRequest(
      framerate: 60, bitrateMbps: 8, duration: .seconds(60),
      destination: URL(filePath: "/out/x.mp4"))
    let phases = try #require(StepPhases.expected(for: .composite(request)))
    #expect(phases.phases.count == 1)
    // The parser stamps this exact phase, so the bar can place a status line.
    #expect(phases.index(matching: StepProgress(phase: "Compositing")) == 0)
  }
}
