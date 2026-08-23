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
