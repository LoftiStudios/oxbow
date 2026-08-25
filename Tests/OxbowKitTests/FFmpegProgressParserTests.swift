import Foundation
import Testing
@testable import OxbowKit

@Suite("FFmpeg progress parser")
struct FFmpegProgressParserTests {

  /// Real captured output. Note `out_time_ms` carries MICROSECONDS — it and
  /// `out_time_us` both read 4983333 for 4.983 seconds.
  private let block = """
    frame=300
    fps=141.68
    stream_0_0_q=-0.0
    bitrate=10292.8kbits/s
    total_size=6411550
    out_time_us=4983333
    out_time_ms=4983333
    out_time=00:00:04.983333
    dup_frames=0
    drop_frames=0
    speed=2.35x
    progress=continue

    """

  private func lines(_ text: String, duration: Duration = .seconds(10)) -> [ParsedLine] {
    var parser = FFmpegProgressParser(duration: duration)
    return parser.consume(Array(text.utf8))
  }

  @Test func reportsAFractionOfTheKnownDuration() throws {
    let progress = try #require(lines(block).compactMap { line -> StepProgress? in
      if case .status(let p) = line { return p } else { return nil }
    }.last)
    let fraction = try #require(progress.fraction)
    #expect(abs(fraction - 0.4983333) < 0.0001)
  }

  /// FFmpeg never reports a total, so the ETA comes from its own `speed`.
  @Test func derivesRemainingFromSpeed() throws {
    let progress = try #require(lines(block).compactMap { line -> StepProgress? in
      if case .status(let p) = line { return p } else { return nil }
    }.last)
    // (10s - 4.983s) / 2.35x = 2.135s. Asserted as a range, not equality:
    // Duration.seconds(Double) keeps the fraction, so == .seconds(2) fails.
    let remaining = try #require(progress.remaining)
    #expect(remaining > .seconds(2) && remaining < .seconds(2.2))
  }

  /// Reading a clock is not this type's job; `StepProgress` is all-optional
  /// precisely so a parser can decline to fill a field.
  @Test func neverReportsElapsed() {
    for line in lines(block) {
      if case .status(let p) = line { #expect(p.elapsed == nil) }
    }
  }

  /// Early blocks report a degenerate rate. Dividing by it must not trap or
  /// produce an infinite ETA.
  @Test func guardsAgainstAZeroSpeed() throws {
    let zeroed = block.replacingOccurrences(of: "speed=2.35x", with: "speed=0x")
    let progress = try #require(lines(zeroed).compactMap { line -> StepProgress? in
      if case .status(let p) = line { return p } else { return nil }
    }.last)
    #expect(progress.remaining == nil)
    #expect(progress.fraction != nil)
  }

  @Test func toleratesNotAvailableTimes() {
    let na = block.replacingOccurrences(of: "out_time_us=4983333", with: "out_time_us=N/A")
    let progress = lines(na).compactMap { line -> StepProgress? in
      if case .status(let p) = line { return p } else { return nil }
    }.last
    #expect(progress?.fraction == nil)
  }

  /// The bytes arrive in whatever chunks the pipe hands over, which is never
  /// aligned to a block.
  @Test func reassemblesABlockSplitAcrossChunks() throws {
    var parser = FFmpegProgressParser(duration: .seconds(10))
    let bytes = Array(block.utf8)
    let cut = bytes.count / 3
    var produced = parser.consume(bytes[..<cut])
    produced += parser.consume(bytes[cut...])
    let progress = try #require(produced.compactMap { line -> StepProgress? in
      if case .status(let p) = line { return p } else { return nil }
    }.last)
    #expect(progress.fraction != nil)
  }

  @Test func reportsCompletionOnTheFinalBlock() throws {
    let final = block.replacingOccurrences(of: "progress=continue", with: "progress=end")
    let progress = try #require(lines(final).compactMap { line -> StepProgress? in
      if case .status(let p) = line { return p } else { return nil }
    }.last)
    #expect(progress.fraction == 1.0)
  }
}
