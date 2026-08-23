import Foundation
import Testing
@testable import OxbowKit

@Suite("StatusLineParser against captured CLI output")
struct StatusLineParserFixtureTests {

  /// The headline case: 401 progress updates arrive inside FOUR newline-
  /// delimited lines. A `\n`-splitting parser reports 4, not 401.
  @Test func recoversAllUpdatesFromChatRender() throws {
    var parser = StatusLineParser()
    let lines = parser.consume(try Fixture.bytes("chatrender-success.stdout"))

    let statuses = lines.compactMap { line -> StepProgress? in
      if case .status(let p) = line { return p }
      return nil
    }

    #expect(statuses.count > 300, "expected hundreds of updates, got \(statuses.count)")
    #expect(statuses.last?.fraction == 1.0)
    #expect(statuses.contains { $0.phase == "Rendering Video" })
  }

  /// Chunk boundaries must not change the result. Byte-at-a-time is the
  /// cruellest case and the one a pipe can genuinely produce.
  @Test(arguments: [1, 7, 64, 4096])
  func producesIdenticalOutputAtAnyChunkSize(chunkSize: Int) throws {
    let bytes = try Fixture.bytes("chatrender-success.stdout")

    var whole = StatusLineParser()
    let expected = whole.consume(bytes)

    var chunked = StatusLineParser()
    var actual: [ParsedLine] = []
    for start in stride(from: 0, to: bytes.count, by: chunkSize) {
      let end = min(start + chunkSize, bytes.count)
      actual += chunked.consume(bytes[start..<end])
    }
    if let tail = chunked.finish() { actual.append(tail) }

    #expect(actual == expected)
  }

  @Test func recoversVideoDownloadPhases() throws {
    var parser = StatusLineParser()
    let lines = parser.consume(try Fixture.bytes("videodownload-success.stdout"))

    let phases = lines.compactMap { line -> String? in
      if case .status(let p) = line { return p.phase }
      return nil
    }

    #expect(phases.contains("Fetching Video Info"))
    #expect(phases.contains("Downloading"))
    #expect(phases.contains("Verifying Parts"))
    #expect(phases.contains("Finalizing Video"))
  }

  /// `chatdownload` emits the no-counter shape.
  @Test func recoversChatDownloadWithoutCounters() throws {
    var parser = StatusLineParser()
    let lines = parser.consume(try Fixture.bytes("chatdownload-success.stdout"))

    let statuses = lines.compactMap { line -> StepProgress? in
      if case .status(let p) = line { return p }
      return nil
    }

    #expect(statuses.allSatisfy { $0.index == nil })
    #expect(statuses.contains { $0.phase == "Backfilling Commenter Info" })
  }
}
