import Foundation

/// Incrementally recovers progress from `ffmpeg -progress pipe:1`.
///
/// The sibling of `StatusLineParser`, and pure the same way: no clock, no I/O.
/// This is the ONLY type that knows FFmpeg's progress protocol.
///
/// FFmpeg emits repeating blocks of `key=value` lines terminated by
/// `progress=continue`, with a final `progress=end`. It never reports a total
/// duration, which is why one is supplied at init.
public struct FFmpegProgressParser: Sendable {
  private let duration: Duration
  private var buffer: [UInt8] = []
  private var fields: [String: String] = [:]

  public init(duration: Duration) {
    self.duration = duration
  }

  /// Feed bytes as they arrive. A block is only complete at its `progress=`
  /// terminator, so most calls return an empty array.
  public mutating func consume(_ bytes: some Sequence<UInt8>) -> [ParsedLine] {
    var lines: [ParsedLine] = []
    for byte in bytes {
      if byte == UInt8(ascii: "\n") {
        if let line = flush() { lines.append(line) }
      } else if byte != UInt8(ascii: "\r") {
        buffer.append(byte)
      }
    }
    return lines
  }

  /// Emit anything still buffered. FFmpeg's final `progress=end` line is
  /// normally newline-terminated, so this is usually a no-op in practice.
  public mutating func finish() -> ParsedLine? {
    flush()
  }

  private mutating func flush() -> ParsedLine? {
    defer { buffer.removeAll(keepingCapacity: true) }
    guard !buffer.isEmpty else { return nil }

    let text = String(decoding: buffer, as: UTF8.self)
    guard let separator = text.firstIndex(of: "=") else { return nil }
    let key = String(text[..<separator])
    let value = String(text[text.index(after: separator)...])
    fields[key] = value

    // A block is only complete at its `progress=` terminator.
    guard key == "progress" else { return nil }
    defer { fields.removeAll(keepingCapacity: true) }
    return .status(progress(isFinal: value == "end"))
  }

  private func progress(isFinal: Bool) -> StepProgress {
    var result = StepProgress(phase: "Compositing")

    // `out_time_us`, NOT `out_time_ms`: FFmpeg's `out_time_ms` is actually
    // microseconds — both fields read 4983333 for 4.983 seconds. Verified
    // 2026-08-25. Do not "fix" this.
    //
    // Known quirk on a resumed composite (docs/design/resume.md §4): FFmpeg
    // reports `out_time_us` as the max across every output in the
    // invocation, not just the piece. When a resume also rewrites the
    // sidecar, that second output spans the whole content window while the
    // piece spans only the tail, so this fraction can read close to or at 1
    // before the encode is actually done. FFmpeg's own dts balancing bounds
    // how far the lead runs, so it is a cosmetic tail effect on the number
    // reported here, not a stalled or stuck job. Do not restructure progress
    // reporting to fix it.
    let total = Double(duration.components.seconds)
    let elapsed = fields["out_time_us"].flatMap(Double.init).map { $0 / 1_000_000 }

    if isFinal {
      result.fraction = 1
    } else if let elapsed, total > 0 {
      result.fraction = min(max(elapsed / total, 0), 1)
    }

    // FFmpeg reports no total, so the ETA comes from its own reported rate.
    let speed = fields["speed"].flatMap { Double($0.dropLast()) }

    // Reported unconditionally (including the degenerate `0.00x` FFmpeg
    // emits on its first few blocks) so the UI can tell "genuinely slow" from
    // "no data yet" apart from a stalled `remaining`.
    result.speed = speed

    // Early blocks report a degenerate speed (e.g. `0.00x`); dividing by it
    // would give an infinite remaining time, so it is simply not reported.
    if let elapsed, let speed, speed > 0, total > elapsed {
      result.remaining = .seconds((total - elapsed) / speed)
    }

    // `elapsed` is deliberately never set: deriving it means reading a clock,
    // which a pure parser does not get to do.
    return result
  }
}
