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

  /// Only include the embed-images phase when requested.
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

  /// Renderer drops its counter during Rendering Video; phase names must still advance
  /// progress.
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

  /// Unknown names fall back to valid counters.
  @Test func fallsBackToTheCounterWhenTheNameIsUnrecognised() {
    let phases = StepPhases.expected(for: video())
    #expect(phases?.index(matching: progress("Reticulating Splines", index: 3, total: 4)) == 2)
  }

  /// Reject mismatched totals from nested helper phase sequences.
  @Test func refusesTheCounterWhenItDisagreesAboutTheNumberOfPhases() {
    let phases = StepPhases.expected(for: video())
    #expect(phases?.index(matching: progress("Reticulating Splines", index: 1, total: 2)) == nil)
  }

  @Test func placesNothingWithNeitherANameNorACounter() {
    #expect(StepPhases.expected(for: video())?.index(matching: progress(nil)) == nil)
  }

  // MARK: - Against the real captured output

  /// Replay captured output to pin phase names; recaptured upstream changes must remain
  /// placeable.
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

  /// Render fixture covers its counterless second phase.
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
      framerate: 60, duration: .seconds(60),
      destination: URL(filePath: "/out/x.mp4"))
    let phases = try #require(StepPhases.expected(for: .composite(request)))
    #expect(phases.phases.count == 1)
    // The parser stamps this exact phase, so the bar can place a status line.
    #expect(phases.index(matching: StepProgress(phase: "Compositing")) == 0)
  }
}
