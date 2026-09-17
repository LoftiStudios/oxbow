import Foundation

/// Parses `ffmpeg -progress pipe:1` key-value blocks, completed by `progress=continue` or
/// `progress=end`. Total duration is supplied because FFmpeg does not report it.
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

    // Use `out_time_us`: despite its name, `out_time_ms` also contains microseconds. On resume,
    // FFmpeg reports the maximum across piece and sidecar outputs, so rewriting full-length
    // audio may briefly push progress ahead of the tail encode. See `docs/design/resume.md` §4.
    let total = Double(duration.components.seconds)
    let elapsed = fields["out_time_us"].flatMap(Double.init).map { $0 / 1_000_000 }

    if isFinal {
      result.fraction = 1
    } else if let elapsed, total > 0 {
      result.fraction = min(max(elapsed / total, 0), 1)
    }

    // FFmpeg reports no total, so the ETA comes from its own reported rate.
    let speed = fields["speed"].flatMap { Double($0.dropLast()) }

    // Report even zero speed to distinguish a slow encode from missing data.
    result.speed = speed

    // `total_size=N/A` means unknown, not zero; zero would produce a zero-byte projection.
    result.bytesWritten = fields["total_size"].flatMap(Int.init)

    // Do not derive ETA from an initial zero speed.
    if let elapsed, let speed, speed > 0, total > elapsed {
      result.remaining = .seconds((total - elapsed) / speed)
    }

    // Elapsed time requires a clock and is not set by this parser.
    return result
  }
}
