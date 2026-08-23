/// The CLI's log preambles, minus `[STATUS]` (which becomes `.status`) and
/// `<FFMPEG> ` (which has no ` - ` separator and becomes `.ffmpeg`).
public enum LogLevel: Sendable, Equatable {
  case verbose, info, warning, error
}
