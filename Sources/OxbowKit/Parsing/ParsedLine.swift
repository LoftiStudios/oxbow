/// Parsed helper output, insulating consumers from the CLI's text protocol.
public enum ParsedLine: Sendable, Equatable {
  case status(StepProgress)
  case log(level: LogLevel, message: String)
  case ffmpeg(String)
}
