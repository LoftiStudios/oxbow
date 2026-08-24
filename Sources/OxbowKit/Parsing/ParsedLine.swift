/// One line recovered from the helper's output.
///
/// Nothing outside `StatusLineParser` touches the CLI's raw text. If upstream
/// ever ships `--progress-format json`, this stays and the parser changes.
public enum ParsedLine: Sendable, Equatable {
  case status(StepProgress)
  case log(level: LogLevel, message: String)
  case ffmpeg(String)
}
