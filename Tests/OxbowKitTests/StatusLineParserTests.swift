import Testing
@testable import OxbowKit

@Suite("StatusLineParser line splitting")
struct StatusLineParserSplittingTests {

  /// The CLI writes progress with `\r`, never `\n`, and does not check whether
  /// stdout is a terminal. A `\n`-only splitter sees one line here, not three.
  @Test func splitsOnCarriageReturn() {
    var parser = StatusLineParser()
    let input = "[INFO] - one\r[INFO] - two\r[INFO] - three\n"

    let lines = parser.consume(Array(input.utf8))

    #expect(lines == [
      .log(level: .info, message: "one"),
      .log(level: .info, message: "two"),
      .log(level: .info, message: "three"),
    ])
  }

  /// `\r\n` together must not produce a phantom empty line.
  @Test func treatsCarriageReturnNewlinePairAsOneBreak() {
    var parser = StatusLineParser()
    let lines = parser.consume(Array("[INFO] - one\r\n[INFO] - two\n".utf8))
    #expect(lines.count == 2)
  }

  /// The CLI pads short lines with spaces to overwrite longer previous ones.
  @Test func stripsOverwritePadding() {
    var parser = StatusLineParser()
    let lines = parser.consume(Array("[INFO] - padded     \r".utf8))
    #expect(lines == [.log(level: .info, message: "padded")])
  }

  /// A line split across two reads must emit exactly once, when it completes.
  @Test func buffersAcrossChunkBoundaries() {
    var parser = StatusLineParser()
    #expect(parser.consume(Array("[INFO] - hal".utf8)).isEmpty)
    #expect(parser.consume(Array("f\n".utf8)) == [.log(level: .info, message: "half")])
  }
}

@Suite("StatusLineParser preambles")
struct StatusLineParserPreambleTests {

  @Test(arguments: [
    ("[VERBOSE] - v", LogLevel.verbose, "v"),
    ("[INFO] - i", LogLevel.info, "i"),
    ("[WARNING] - w", LogLevel.warning, "w"),
    ("[ERROR] - e", LogLevel.error, "e"),
  ])
  func classifiesLogPreambles(input: String, level: LogLevel, message: String) {
    #expect(StatusLineParser.classify(input) == .log(level: level, message: message))
  }

  /// `<FFMPEG> ` is the one preamble with no ` - ` separator.
  @Test func classifiesFfmpegPreambleWhichHasNoSeparator() {
    #expect(StatusLineParser.classify("<FFMPEG> frame= 60") == .ffmpeg("frame= 60"))
  }

  @Test func classifiesStatusPreamble() {
    guard case .status = StatusLineParser.classify("[STATUS] - Downloading 50%") else {
      Issue.record("expected .status")
      return
    }
  }

  /// Unrecognised output must never be dropped — it is often the useful part.
  @Test func treatsUnrecognisedTextAsInfo() {
    #expect(StatusLineParser.classify("bare text") == .log(level: .info, message: "bare text"))
  }
}

@Suite("StatusLineParser status shapes")
struct StatusLineParserStatusTests {

  /// Shape 1: phase plus step counter, no percentage.
  @Test func parsesPhaseAndCounter() {
    let p = StatusLineParser.parseProgress("Fetching Video Info [1/4]")
    #expect(p.phase == "Fetching Video Info")
    #expect(p.fraction == nil)
    #expect(p.index == 1)
    #expect(p.total == 4)
  }

  /// Shape 2: phase, percentage, and counter.
  @Test func parsesPhasePercentAndCounter() {
    let p = StatusLineParser.parseProgress("Downloading 100% [2/4]")
    #expect(p.phase == "Downloading")
    #expect(p.fraction == 1.0)
    #expect(p.index == 2)
    #expect(p.total == 4)
  }

  /// Shape 3: phase and percentage, no counter. Emitted by `chatdownload`.
  @Test func parsesPhaseAndPercentWithoutCounter() {
    let p = StatusLineParser.parseProgress("Downloading 25%")
    #expect(p.phase == "Downloading")
    #expect(p.fraction == 0.25)
    #expect(p.index == nil)
    #expect(p.total == nil)
  }

  /// Shape 4: phase, percentage, elapsed and remaining. Emitted by `chatrender`.
  @Test func parsesPhasePercentAndTimes() {
    let p = StatusLineParser.parseProgress("Rendering Video 45% (0h1m5s Elapsed | 2h0m3s Remaining)")
    #expect(p.phase == "Rendering Video")
    #expect(p.fraction == 0.45)
    #expect(p.elapsed == .seconds(65))
    #expect(p.remaining == .seconds(7203))
  }

  /// A phase containing a digit must not be mistaken for a percentage.
  @Test func doesNotMistakeDigitsInPhaseForPercent() {
    let p = StatusLineParser.parseProgress("Combining Parts 2 [3/5]")
    #expect(p.phase == "Combining Parts 2")
    #expect(p.fraction == nil)
  }
}
