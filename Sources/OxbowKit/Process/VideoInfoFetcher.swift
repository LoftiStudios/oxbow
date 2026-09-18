import Foundation

/// What can go wrong asking the helper for a video's metadata.
public enum VideoInfoFetchError: Error, Equatable {
  /// The helper did not exit cleanly. Carries `standardError` because, like
  /// every other CLI failure, the useful sentence is usually in there.
  case helperFailed(status: ProcessExitStatus, standardError: String)
  /// Clean exit with unparseable stdout. Retains a bounded snippet to diagnose changes in
  /// upstream's raw format.
  case unparseableOutput(snippet: String)
}

/// Runs CLI `info` before enqueueing; metadata fetches produce no queue artifact. Accepts
/// either a VOD ID or clip slug without depending on app-layer link types.
public enum VideoInfoFetcher {

  /// Maximum characters retained in an unparseable-output diagnostic; pinned by tests.
  static let snippetLimit = 280

  /// Isolated output buffer because the Sendable callback does not guarantee single-threaded
  /// calls.
  private actor OutputCollector {
    private var lines: [String] = []
    func append(_ line: String) { lines.append(line) }
    var joined: String { lines.joined(separator: "\n") }
  }

  /// Parsed metadata and retained payload for future parsers. Payload joins log/FFmpeg lines,
  /// omitting status banners and blank lines; it is not a byte-for-byte process transcript.
  public struct Fetched: Sendable {
    public let info: VideoInfo
    public let payload: String

    public init(info: VideoInfo, payload: String) {
      self.info = info
      self.payload = payload
    }
  }

  /// Runs `info --format Raw`. Collect JSON and playlist from log/FFmpeg events; ignore the
  /// leading status banner.
  public static func fetchDetailed(
    id: String,
    helper: URL,
    process: HelperProcessing)
    async throws -> Fetched
  {
    let launch = Launch(
      executable: helper,
      arguments: ArgumentBuilder.infoArguments(id: id),
      // `info` writes nothing to disk — no `-o`, no `--temp-path` — so this
      // only has to exist for `posix_spawn`'s chdir to succeed.
      workingDirectory: FileManager.default.temporaryDirectory)

    let collector = OutputCollector()

    // Forward task cancellation to the subprocess; cancelling an async waiter alone does not
    // stop it. The synchronous handler dispatches async `cancel`, whose permanent flag also
    // covers cancellation before spawn.
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

    // Cancellation is not a metadata failure to display while the user edits a link.
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

    return Fetched(info: info, payload: joined)
  }

  /// Metadata-only convenience for callers that do not retain the payload.
  public static func fetch(
    id: String,
    helper: URL,
    process: HelperProcessing)
    async throws -> VideoInfo
  {
    try await fetchDetailed(id: id, helper: helper, process: process).info
  }

  /// Truncates `output` to `snippetLimit`, leaving a visible marker so the
  /// snippet is never mistaken for the whole thing.
  private static func snippet(of output: String) -> String {
    guard output.count > snippetLimit else { return output }
    let truncated = output.prefix(snippetLimit)
    return "\(truncated)… [truncated, \(output.count) characters total]"
  }
}
