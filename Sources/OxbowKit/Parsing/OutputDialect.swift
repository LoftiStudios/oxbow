import Foundation

/// Which text protocol a launched process speaks on stdout.
///
/// An enum rather than an injected parser: it keeps `Launch` `Sendable`
/// without a capture, and it keeps the choice table-driven in tests.
public enum OutputDialect: Sendable, Equatable {
  /// TwitchDownloaderCLI's `[STATUS]` / `[INFO]` / `<FFMPEG>` lines.
  case helper
  /// FFmpeg's `-progress pipe:1` key-value blocks. Carries the total duration
  /// because FFmpeg never reports one.
  case ffmpeg(duration: Duration)
}

/// The concrete parsers, unified without an existential.
enum DialectParser {
  case helper(StatusLineParser)
  case ffmpeg(FFmpegProgressParser)

  init(_ dialect: OutputDialect) {
    switch dialect {
    case .helper: self = .helper(StatusLineParser())
    case .ffmpeg(let duration): self = .ffmpeg(FFmpegProgressParser(duration: duration))
    }
  }

  mutating func consume(_ bytes: some Sequence<UInt8>) -> [ParsedLine] {
    switch self {
    case .helper(var parser):
      defer { self = .helper(parser) }
      return parser.consume(bytes)
    case .ffmpeg(var parser):
      defer { self = .ffmpeg(parser) }
      return parser.consume(bytes)
    }
  }

  mutating func finish() -> ParsedLine? {
    switch self {
    case .helper(var parser):
      defer { self = .helper(parser) }
      return parser.finish()
    case .ffmpeg(var parser):
      defer { self = .ffmpeg(parser) }
      return parser.finish()
    }
  }
}
