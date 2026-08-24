import Foundation

/// What can go wrong asking the helper for a video's metadata.
public enum VideoInfoFetchError: Error, Equatable {
  /// The helper did not exit cleanly. Carries `standardError` because, like
  /// every other CLI failure, the useful sentence is usually in there.
  case helperFailed(status: ProcessExitStatus, standardError: String)
  /// The helper exited cleanly but its stdout did not contain a line
  /// `VideoInfo.parse` could make sense of.
  case unparseableOutput
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
    let result = try await process.run(launch) { line in
      switch line {
      case .log(_, let message): await collector.append(message)
      case .ffmpeg(let message): await collector.append(message)
      case .status: break
      }
    }

    guard case .exited(0) = result.status else {
      throw VideoInfoFetchError.helperFailed(
        status: result.status,
        standardError: result.standardError)
    }

    guard let info = VideoInfo.parse(await collector.joined) else {
      throw VideoInfoFetchError.unparseableOutput
    }

    return info
  }
}
