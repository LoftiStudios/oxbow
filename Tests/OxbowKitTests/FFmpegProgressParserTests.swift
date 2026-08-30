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

  /// `total_size` is the only signal the app has for how big a composite is
  /// becoming.
  ///
  /// `.composite` asks the encoder for a quality rather than a bitrate
  /// (`composite-rate-control.md`), so the output size is not knowable in
  /// advance — and §7.1 there establishes that it cannot be capped either,
  /// because `-maxrate` displaces quality targeting instead of bounding it.
  /// The mitigation is that a runaway encode announces itself: bytes written
  /// over fraction complete is a live projection that converges early.
  ///
  /// FFmpeg has always emitted this; it was simply never read.
  @Test func reportsBytesWrittenSoFar() throws {
    let progress = try #require(lines(block).compactMap { line -> StepProgress? in
      if case .status(let p) = line { return p } else { return nil }
    }.last)
    #expect(progress.bytesWritten == 6_411_550)
  }

  /// `total_size=N/A` appears before the first packet is muxed. It is the
  /// absence of a number, not a zero.
  @Test func treatsAnUnavailableSizeAsAbsent() throws {
    let text = block.replacingOccurrences(of: "total_size=6411550", with: "total_size=N/A")
    let progress = try #require(lines(text).compactMap { line -> StepProgress? in
      if case .status(let p) = line { return p } else { return nil }
    }.last)
    #expect(progress.bytesWritten == nil)
  }

  // MARK: - Projected size

  /// Bytes so far over fraction complete. The composite's size is unknowable
  /// in advance under a quality target, so this is the only number that can
  /// warn anyone a job is heading somewhere unexpected.
  @Test func projectsTheFinalSizeFromBytesAndProgress() {
    let p = StepProgress(fraction: 0.25, bytesWritten: 1_000_000_000)
    #expect(p.projectedBytes == 4_000_000_000)
  }

  /// The first blocks are all I-frames and a tiny denominator, so an early
  /// projection is not wrong so much as meaningless — 0.3% complete would
  /// project a wildly inflated total and then visibly collapse, which reads as
  /// a broken number rather than a converging one.
  @Test func refusesToProjectFromTheFirstFewPercent() {
    #expect(StepProgress(fraction: 0.003, bytesWritten: 50_000_000).projectedBytes == nil)
    #expect(StepProgress(fraction: 0, bytesWritten: 50_000_000).projectedBytes == nil)
  }

  @Test func hasNoProjectionWithoutBytes() {
    #expect(StepProgress(fraction: 0.5).projectedBytes == nil)
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

  /// `speed` is reported independently of `remaining` — the UI's only way to
  /// tell a genuinely slow encode apart from a stalled one, even before
  /// there is enough data for an ETA.
  @Test func reportsSpeedEvenWhenDegenerate() throws {
    let zeroed = block.replacingOccurrences(of: "speed=2.35x", with: "speed=0x")
    let progress = try #require(lines(zeroed).compactMap { line -> StepProgress? in
      if case .status(let p) = line { return p } else { return nil }
    }.last)
    #expect(progress.speed == 0)
  }

  @Test func reportsSpeed() throws {
    let progress = try #require(lines(block).compactMap { line -> StepProgress? in
      if case .status(let p) = line { return p } else { return nil }
    }.last)
    #expect(progress.speed == 2.35)
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
