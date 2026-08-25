import Foundation

/// What can go wrong asking the helper for a video's metadata.
public enum VideoInfoFetchError: Error, Equatable {
  /// The helper did not exit cleanly. Carries `standardError` because, like
  /// every other CLI failure, the useful sentence is usually in there.
  case helperFailed(status: ProcessExitStatus, standardError: String)
  /// The helper exited cleanly but its stdout did not contain a line
  /// `VideoInfo.parse` could make sense of. Carries a bounded snippet of the
  /// joined output — `Raw`'s shape is not a stable upstream contract (see
  /// `VideoInfo`'s doc comment), and a bare case name gives whoever debugs a
  /// format drift nothing to go on. This is the same lesson `StepLog` exists
  /// for: capturing helper output and then discarding it is how a diagnosable
  /// failure turns into one that needs a process sample instead.
  case unparseableOutput(snippet: String)
}

/// Fetches one video's metadata by running the CLI's `info` verb directly.
///
/// Deliberately **not a queue step**: it produces no artifact, has no place
/// in the job model, and must never appear in the queue list. Intake calls
/// this once, before a job exists, to derive an output filename and offer a
/// quality picker (docs/design/chat-and-render.md §3).
///
/// A plain `String` id rather than `TwitchLink.Target`: that type lives in
/// the app target, which `OxbowKit` cannot see, and does not need to — the
/// CLI's `info --id` accepts a VOD id and a clip slug identically, so the
/// caller resolves which it holds and passes the string.
public enum VideoInfoFetcher {

  /// How much of the unparseable output `.unparseableOutput` keeps, in
  /// `Character`s. Enough to show what upstream actually sent; bounded so a
  /// runaway payload (a very chatty helper, or a genuinely wrong invocation)
  /// can never balloon an error string to megabytes.
  ///
  /// Not `private`: `VideoInfoFetcherTests` pins this bound so a future edit
  /// can't accidentally make it unbounded again.
  static let snippetLimit = 280

  /// Accumulates the helper's narrative output.
  ///
  /// An actor, not a captured local `var`: `onOutput` is `@Sendable` and
  /// nothing about `HelperProcessing.run` promises its calls stay on one
  /// thread, so appending needs real isolation, not just sequential-in-
  /// practice ordering.
  private actor OutputCollector {
    private var lines: [String] = []
    func append(_ line: String) { lines.append(line) }
    var joined: String { lines.joined(separator: "\n") }
  }

  /// Runs `info --id <id> --format Raw` and parses the result.
  ///
  /// The info payload — the video-info JSON, the moments JSON, and the m3u8
  /// master playlist — arrives on `onOutput` as `.log`/`.ffmpeg` lines, not
  /// `.status`: nothing in that body matches one of the CLI's `[STATUS] - `
  /// preambles, so `StatusLineParser` classifies it as narrative output (see
  /// `StepLog`'s doc comment for the same distinction). Only the leading
  /// `[STATUS] - Fetching Video Info [1/1]` banner is `.status`, and it is
  /// ignored here — `VideoInfo.parse` finds its own start point regardless.
  public static func fetch(
    id: String,
    helper: URL,
    process: HelperProcessing)
    async throws -> VideoInfo
  {
    let launch = Launch(
      executable: helper,
      arguments: ArgumentBuilder.infoArguments(id: id),
      // `info` writes nothing to disk — no `-o`, no `--temp-path` — so this
      // only has to exist for `posix_spawn`'s chdir to succeed.
      workingDirectory: FileManager.default.temporaryDirectory)

    let collector = OutputCollector()

    // Cancelling this task has to reach the child, or it does not reach
    // anything: `HelperProcess.run` blocks on `waitpid` and observes nothing
    // about the task it is running on. Intake refetches on every keystroke
    // (debounced), and SwiftUI's `.task(id:)` cancels the previous fetch when
    // the link changes — so without this, typing a URL a character at a time
    // leaves an `info` subprocess per keystroke running to completion, each
    // one talking to Twitch, all of their results discarded.
    //
    // `cancel()` is async and this handler is not, so it goes through a
    // detached task; `HelperProcess.cancel` is a one-way flag, so arriving
    // before the spawn is as good as arriving after it.
    let result = try await withTaskCancellationHandler {
      try await process.run(launch) { line in
        switch line {
        case .log(_, let message): await collector.append(message)
        case .ffmpeg(let message): await collector.append(message)
        case .status: break
        }
      }
    } onCancel: {
      Task { await process.cancel() }
    }

    // A cancelled fetch has no answer, and must not be reported as a helper
    // failure: the caller asked for this to stop, and `.helperFailed` would
    // put "Oxbow could not read that video's details" in front of a user who
    // simply carried on typing.
    try Task.checkCancellation()

    guard case .exited(0) = result.status else {
      throw VideoInfoFetchError.helperFailed(
        status: result.status,
        standardError: result.standardError)
    }

    let joined = await collector.joined
    guard let info = VideoInfo.parse(joined) else {
      throw VideoInfoFetchError.unparseableOutput(snippet: Self.snippet(of: joined))
    }

    return info
  }

  /// Truncates `output` to `snippetLimit`, leaving a visible marker so the
  /// snippet is never mistaken for the whole thing.
  private static func snippet(of output: String) -> String {
    guard output.count > snippetLimit else { return output }
    let truncated = output.prefix(snippetLimit)
    return "\(truncated)… [truncated, \(output.count) characters total]"
  }
}
