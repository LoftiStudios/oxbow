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

  /// Filled in by Task 3.
  static func parseProgress(_ text: String) -> StepProgress {
    StepProgress(phase: text)
  }
}

extension String {
  /// Returns the remainder after `prefix`, or nil if the prefix is absent.
  func strippingPrefix(_ prefix: String) -> String? {
    hasPrefix(prefix) ? String(dropFirst(prefix.count)) : nil
  }
}
