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

    // 403 is the recorded count for this fixture, verified byte-for-byte:
    // 401 `\r` + 4 `\n` = 405 delimiters, and the fixture contains no `\r\n`
    // pair, so each one ends a line. Two of those 405 lines are `[INFO]`
    // rather than `[STATUS]`. Pinned exactly rather than thresholded, because
    // the fixture is never regenerated: a regression that silently dropped
    // updates would still satisfy `> 300` but must fail here.
    #expect(statuses.count == 403, "expected exactly 403 updates for this fixture, got \(statuses.count)")
    #expect(statuses.last?.fraction == 1.0)
    #expect(statuses.contains { $0.phase == "Rendering Video" })
  }

  /// Chunk boundaries must not change the result. Byte-at-a-time is the
  /// cruellest case and the one a pipe can genuinely produce.
  @Test(arguments: [1, 7, 64, 4096])
  func producesIdenticalOutputAtAnyChunkSize(chunkSize: Int) throws {
    let bytes = try Fixture.bytes("chatrender-success.stdout")

    var whole = StatusLineParser()
    var expected = whole.consume(bytes)
    if let tail = whole.finish() { expected.append(tail) }

    var chunked = StatusLineParser()
    var actual: [ParsedLine] = []
    for start in stride(from: 0, to: bytes.count, by: chunkSize) {
      let end = min(start + chunkSize, bytes.count)
      actual += chunked.consume(bytes[start..<end])
    }
    if let tail = chunked.finish() { actual.append(tail) }

    #expect(actual == expected)
  }

  /// A killed process can leave its final line unterminated. Derive that
  /// case from the real fixture (drop its trailing `\n`) rather than
  /// inventing a hand-written string, so it still stands in for real bytes.
  @Test func recoversTrailingPartialLineOnFinish() throws {
    var bytes = try Fixture.bytes("chatrender-success.stdout")
    #expect(bytes.last == UInt8(ascii: "\n"), "fixture is expected to end in a newline before truncation")
    bytes.removeLast()

    var withoutFinish = StatusLineParser()
    let linesBeforeFinish = withoutFinish.consume(bytes)
    let tail = withoutFinish.finish()

    // (a) finish() on the truncated bytes recovers exactly one more line
    // than consume() alone did — the unterminated final line.
    #expect(tail != nil, "finish() should recover the unterminated final line")
    var linesAfterFinish = linesBeforeFinish
    if let tail { linesAfterFinish.append(tail) }
    #expect(linesAfterFinish.count == linesBeforeFinish.count + 1)

    // (b) chunked and whole-buffer parsing of the truncated bytes still agree.
    var whole = StatusLineParser()
    var expected = whole.consume(bytes)
    if let wholeTail = whole.finish() { expected.append(wholeTail) }
    #expect(expected == linesAfterFinish)

    for chunkSize in [1, 7, 64, 4096] {
      var chunked = StatusLineParser()
      var actual: [ParsedLine] = []
      for start in stride(from: 0, to: bytes.count, by: chunkSize) {
        let end = min(start + chunkSize, bytes.count)
        actual += chunked.consume(bytes[start..<end])
      }
      if let chunkedTail = chunked.finish() { actual.append(chunkedTail) }

      #expect(actual == expected, "chunk size \(chunkSize) diverged on the truncated fixture")
    }
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
