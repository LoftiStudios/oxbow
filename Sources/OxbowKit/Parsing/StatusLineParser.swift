import Foundation

/// Incrementally recovers lines from the helper's output stream.
///
/// This is the ONLY type that knows the CLI's text protocol.
///
/// The CLI delimits progress updates with `\r` and does not check whether
/// stdout is a terminal, so a real chat render emits 401 updates inside four
/// `\n`-delimited lines. Splitting on `\n` alone produces a frozen progress
/// bar that jumps to 100% at the end. See the design spec, section 1.1.
public struct StatusLineParser: Sendable {
  private var buffer: [UInt8] = []

  public init() {}

  /// Feed bytes as they arrive. Returns whatever complete lines they finished.
  /// An incomplete trailing line is retained until a later call completes it.
  public mutating func consume(_ bytes: some Sequence<UInt8>) -> [ParsedLine] {
    var lines: [ParsedLine] = []
    for byte in bytes {
      if byte == UInt8(ascii: "\n") || byte == UInt8(ascii: "\r") {
        if let line = flush() { lines.append(line) }
      } else {
        buffer.append(byte)
      }
    }
    return lines
  }

  /// Emit anything still buffered. Call when the process has exited, because
  /// the CLI does not always terminate its final line.
  public mutating func finish() -> ParsedLine? {
    flush()
  }

  private mutating func flush() -> ParsedLine? {
    defer { buffer.removeAll(keepingCapacity: true) }

    // A `\r\n` pair flushes twice; the second flush is empty and is not a line.
    guard !buffer.isEmpty else { return nil }

    // Trailing spaces are the CLI overwriting a longer previous line.
    let text = String(decoding: buffer, as: UTF8.self)
      .trimmingCharacters(in: .whitespaces)
    guard !text.isEmpty else { return nil }

    return Self.classify(text)
  }

  /// The CLI's six output preambles, verified against version 1.56.5.
  static func classify(_ text: String) -> ParsedLine {
    if let rest = text.strippingPrefix("[STATUS] - ") {
      return .status(parseProgress(rest))
    }
    if let rest = text.strippingPrefix("[VERBOSE] - ") {
      return .log(level: .verbose, message: rest)
    }
    if let rest = text.strippingPrefix("[INFO] - ") {
      return .log(level: .info, message: rest)
    }
    if let rest = text.strippingPrefix("[WARNING] - ") {
      return .log(level: .warning, message: rest)
    }
    if let rest = text.strippingPrefix("[ERROR] - ") {
      return .log(level: .error, message: rest)
    }
    // Note: no ` - ` separator on this one.
    if let rest = text.strippingPrefix("<FFMPEG> ") {
      return .ffmpeg(rest)
    }
    // Never drop unrecognised output; it is frequently the useful part.
    return .log(level: .info, message: text)
  }

  /// Parses the four status shapes the CLI emits. See the design spec, §1.2.
  ///
  /// Parsed right-to-left: the trailing counter or times group is stripped
  /// first, then the percentage, and the remainder is the phase. Doing it in
  /// this order is what stops a digit inside a phase name being read as a
  /// percentage.
  static func parseProgress(_ text: String) -> StepProgress {
    var remainder = Substring(text)
    var progress = StepProgress()

    if let match = remainder.firstMatch(of: /\s*\[(\d+)\/(\d+)\]$/) {
      progress.index = Int(match.1)
      progress.total = Int(match.2)
      remainder = remainder[..<match.range.lowerBound]
    }

    let times = /\s*\((\d+)h(\d+)m(\d+)s Elapsed \| (\d+)h(\d+)m(\d+)s Remaining\)$/
    if let match = remainder.firstMatch(of: times) {
      progress.elapsed = Self.duration(match.1, match.2, match.3)
      progress.remaining = Self.duration(match.4, match.5, match.6)
      remainder = remainder[..<match.range.lowerBound]
    }

    if let match = remainder.firstMatch(of: /\s+(\d+)%$/) {
      if let percent = Int(match.1) {
        progress.fraction = Double(percent) / 100
      }
      remainder = remainder[..<match.range.lowerBound]
    }

    let phase = remainder.trimmingCharacters(in: .whitespaces)
    progress.phase = phase.isEmpty ? nil : phase
    return progress
  }

  private static func duration(
    _ hours: Substring,
    _ minutes: Substring,
    _ seconds: Substring)
    -> Duration
  {
    let h = Int(hours) ?? 0
    let m = Int(minutes) ?? 0
    let s = Int(seconds) ?? 0
    return .seconds(h * 3600 + m * 60 + s)
  }
}

extension String {
  /// Returns the remainder after `prefix`, or nil if the prefix is absent.
  func strippingPrefix(_ prefix: String) -> String? {
    hasPrefix(prefix) ? String(dropFirst(prefix.count)) : nil
  }
}
