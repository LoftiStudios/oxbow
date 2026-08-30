import Darwin
import Foundation
import Testing
@testable import OxbowKit

/// Drives the resume mechanism against the real bundled binaries and a real
/// VOD: hard-kill a composite mid-encode, simulate the launch sweep, retry,
/// and check the delivered file frame-for-frame and timestamp-for-timestamp
/// against a straight-through encode of the same range.
///
/// **Not part of the default `swift test` run.** It needs network (two short
/// real downloads), real `h264_videotoolbox` encodes, and a few hundred MB of
/// scratch disk — several minutes altogether. Gated behind an environment
/// variable so the ordinary suite never pays for it:
///
/// ```
/// OXBOW_RESUME_E2E=1 swift test --filter ResumeEndToEndTests
/// ```
///
/// Requires `build/helper/TwitchDownloaderCLI` and `build/ffmpeg/ffmpeg` to
/// already exist — `./scripts/build-ffmpeg.sh` and the `dotnet publish`
/// command in `CLAUDE.md`.
///
/// This drives `QueueEngine.makeContext` and `ArgumentBuilder` directly —
/// the same calls `QueueEngine.launch` makes — rather than the actor's own
/// scheduler, so the interruption can be a genuine, precisely-timed
/// `SIGKILL` (a crash, not `HelperProcess.cancel()`'s graceful `SIGTERM`)
/// and so the delivered file can be inspected before anything sweeps it.
@Suite(
  "Resume end-to-end",
  .enabled(if: ProcessInfo.processInfo.environment["OXBOW_RESUME_E2E"] == "1"),
  .serialized)
struct ResumeEndToEndTests {

  /// **Not** the VOD `docs/design/resume.md` and `docs/design/
  /// fragmented-output.md` were originally spiked against (`1480816483`).
  /// That VOD's channel has since gone — its `info` JSON now behaves the
  /// same as every other VOD's (see `rawInfoOutput`'s comment), but its chat
  /// additionally has no working streamer-badge data any more, and
  /// `chatrender` throws (`ArgumentNullException` in
  /// `TwitchHelper.GetChatBadgesData`, `vendor/TwitchDownloader` — read-only)
  /// rather than degrading. A public VOD from a large, currently-live
  /// channel doesn't have that problem. If this one is ever gone too, any
  /// similarly long, currently-live VOD works — nothing below depends on
  /// which one.
  private static let videoID = "2853736315"

  /// 120s of real content: long enough for an ~11s composite (measured
  /// during this test's own design) to interrupt meaningfully partway
  /// through, short enough to keep two real downloads and three real
  /// composite encodes to a few minutes and well under a GB.
  private static let trimStart = Duration.seconds(200)
  private static let trimEnd = Duration.seconds(320)
  private static let contentDuration = trimEnd - trimStart

  /// The chat download's own trim window — deliberately much narrower than
  /// the video's. It has nothing to do with resume or the video: chat and
  /// video are composited by `hstack`, whose `eof_action=repeat` default
  /// (compositing.md) holds the last chat frame for the rest of the video
  /// regardless of how short the chat render is. Kept narrow specifically to
  /// minimise exposure to the live Twitch flake `runWithRetry` documents —
  /// fewer GQL pagination round trips, fewer chances to hit it.
  private static let chatTrimEnd = trimStart + .seconds(5)

  /// Kill the first attempt at 60% of its content, by encoded position, not
  /// wall clock — robust to machine speed, and it leaves an unambiguous,
  /// non-trivial tail for the second attempt to prove it is not redoing.
  private static let killFraction = 0.6

  private struct TestError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
  }

  // MARK: - Binaries

  private func repoRoot() -> URL {
    URL(filePath: #filePath)
      .deletingLastPathComponent()  // Tests/OxbowKitTests/
      .deletingLastPathComponent()  // Tests/
      .deletingLastPathComponent()  // repo root
  }

  private func requireBinary(_ relativePath: String) throws -> URL {
    let url = repoRoot().appending(path: relativePath)
    try #require(
      FileManager.default.fileExists(atPath: url.path),
      "Missing \(relativePath) — build it first (see CLAUDE.md).")
    return url
  }

  // MARK: - Process plumbing

  /// Drains a pipe to EOF on its own thread, off the cooperative pool —
  /// `Spawn`'s own doc comment: an undrained pipe can deadlock the child.
  /// Mirrors `HelperProcess.run`'s technique exactly, reusing its
  /// `BlockingThread` rather than re-inventing it.
  private func drain(_ handle: FileHandle) async -> Data {
    await BlockingThread.run("resume-e2e-drain") {
      var data = Data()
      while true {
        let chunk = handle.availableData
        if chunk.isEmpty { break }
        data.append(chunk)
      }
      return data
    }
  }

  /// Spawns `executable arguments` for real and runs it to completion,
  /// draining both pipes concurrently. When `killAfterMicros` is set, watches
  /// stdout for FFmpeg's `-progress pipe:1` `out_time_us` crossing that
  /// position and fires `SIGKILL` on the whole process group the instant it
  /// does — deliberately not `HelperProcess.cancel()`'s graceful `SIGTERM`,
  /// so the survivor is genuinely torn mid-fragment rather than closed
  /// cleanly (resume.md §2: "not a clean SIGTERM, which lets FFmpeg finalise
  /// and is the easy case").
  ///
  /// Returns the exit status, the captured stderr (for a diagnostic on an
  /// unexpected failure), and the `out_time_us` the kill actually fired at —
  /// `nil` if `killAfterMicros` was never reached, which callers must treat
  /// as a broken test setup, not a passing one.
  @discardableResult
  private func spawnAndRun(
    executable: URL,
    arguments: [String],
    workingDirectory: URL,
    killAfterMicros: Int? = nil)
    async throws -> (status: ProcessExitStatus, stderr: String, killedAtMicros: Int?)
  {
    let spawn = try ProcessSpawner.spawn(
      executable: executable, arguments: arguments, workingDirectory: workingDirectory)

    async let stderrData = drain(spawn.stderr)

    async let killedAtMicros: Int? = BlockingThread.run("resume-e2e-progress") {
      var buffer = Data()
      var firedAt: Int?
      while true {
        let chunk = spawn.stdout.availableData
        if chunk.isEmpty { break }
        buffer.append(chunk)
        while let newline = buffer.firstIndex(of: 0x0A) {
          let line = String(decoding: buffer[buffer.startIndex ..< newline], as: UTF8.self)
          buffer.removeSubrange(buffer.startIndex ... newline)
          guard line.hasPrefix("out_time_us=") else { continue }
          guard let value = Int(line.dropFirst("out_time_us=".count)) else { continue }
          if let threshold = killAfterMicros, firedAt == nil, value >= threshold {
            firedAt = value
            ProcessSpawner.signal(SIGKILL, toGroupOf: spawn.pid)
          }
        }
      }
      return firedAt
    }

    let stderrBytes = await stderrData
    let firedAt = await killedAtMicros
    let status = await BlockingThread.run("resume-e2e-wait") { ProcessSpawner.wait(spawn.pid) }
    return (status, String(decoding: stderrBytes, as: UTF8.self), firedAt)
  }

  /// `kind`'s real argv, run via `spawnAndRun`. `executable` is the helper
  /// for the four CLI verbs and `ffmpeg` for `.composite`/`.assemble` —
  /// callers pass whichever this step needs, matching `QueueEngine.launch`.
  @discardableResult
  private func run(
    _ kind: StepKind, context: StepContext, executable: URL, killAfterMicros: Int? = nil
  ) async throws -> (status: ProcessExitStatus, stderr: String, killedAtMicros: Int?) {
    try await spawnAndRun(
      executable: executable,
      arguments: ArgumentBuilder.arguments(for: kind, context: context),
      workingDirectory: context.stepTempDirectory,
      killAfterMicros: killAfterMicros)
  }

  /// Twitch's GQL backend is intermittently inconsistent under the exact
  /// requests this pinned helper sends — verified independently of the CLI
  /// entirely, with plain `curl` against the identical query
  /// `TwitchHelper.GetVideoInfo` uses: of five back-to-back requests for one
  /// video's `owner`, two came back `null`; a `VideoCommentsByOffsetOrCursor`
  /// pagination request occasionally answers with `data.video: null`
  /// outright. Upstream (`vendor/TwitchDownloader` — read-only, see
  /// CLAUDE.md) does not retry either case — `VideoDownloader.
  /// DownloadAsyncImpl` throws `"Invalid VOD, deleted/expired VOD possibly?"`
  /// and `ChatDownloader.DownloadSection` throws a bare
  /// `NullReferenceException` — so retrying the whole subprocess here, in
  /// the test's own harness, is the only accommodation available that does
  /// not mean patching the vendored submodule. Nothing about this is
  /// specific to resume, the sidecar, or anything this branch changes; it
  /// reproduces with `curl` outside this repo entirely.
  private func runWithRetry(
    _ kind: StepKind, context: StepContext, executable: URL, label: String, attempts: Int = 12
  ) async throws {
    var lastStatus: ProcessExitStatus?
    var lastStderr = ""
    for attempt in 1 ... attempts {
      let result = try await run(kind, context: context, executable: executable)
      if case .exited(0) = result.status, FileManager.default.fileExists(atPath: context.outputFile.path) {
        if attempt > 1 {
          print("\(label) succeeded on attempt \(attempt)/\(attempts).")
        }
        return
      }
      lastStatus = result.status
      lastStderr = result.stderr
      // Backs off rather than hammering the same flaky endpoint at a fixed
      // 1s cadence — a run of consecutive failures (observed: 8 in a row on
      // one `videodownload` retry) reads like a short-lived, load-related
      // dip rather than an even per-request coin flip, so giving it room to
      // clear is worth more than a tight retry loop.
      let backoff = min(attempt * 2, 15)
      print("\(label) attempt \(attempt)/\(attempts) failed (\(result.status)) — retrying in "
        + "\(backoff)s; see runWithRetry's doc comment.")
      try await Task.sleep(for: .seconds(backoff))
    }
    throw TestError(
      "\(label) failed after \(attempts) attempts, all against the same live Twitch GQL flake "
        + "runWithRetry documents (\(lastStatus.map { "\($0)" } ?? "?")):\n\(lastStderr.suffix(1000))")
  }

  // MARK: - Measurement helpers

  private func seconds(_ duration: Duration) -> Double {
    Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
  }

  /// `ffmpeg -hide_banner -i <file> -an -f null -`, parsed for the final
  /// `frame=` — the brief's own frame-count method (resume.md §2, task-11
  /// brief step 4). Never `trim=start_frame` — resume.md §2.1.
  private func frameCount(of file: URL, ffmpeg: URL) async throws -> Int {
    let result = try await spawnAndRun(
      executable: ffmpeg,
      arguments: ["-hide_banner", "-i", file.path, "-an", "-f", "null", "-"],
      workingDirectory: file.deletingLastPathComponent())
    guard case .exited(0) = result.status else {
      throw TestError("frame count decode failed (\(result.status)):\n\(result.stderr.suffix(2000))")
    }
    return try lastInt(matching: #"frame=\s*(\d+)"#, in: result.stderr)
  }

  /// The final `time=` FFmpeg's default stats line reports for a decode —
  /// used both as a completeness check (does it reach the end) and, compared
  /// between an audio-only and a video-only decode of the same file, as a
  /// sync check.
  private func finalTime(of file: URL, extraArgs: [String], ffmpeg: URL) async throws -> Double {
    let result = try await spawnAndRun(
      executable: ffmpeg,
      arguments: ["-hide_banner", "-i", file.path] + extraArgs + ["-f", "null", "-"],
      workingDirectory: file.deletingLastPathComponent())
    guard case .exited(0) = result.status else {
      throw TestError("decode failed (\(result.status)):\n\(result.stderr.suffix(2000))")
    }
    return try lastTimecode(matching: #"time=\s*(\d+):(\d+):(\d+\.\d+)"#, in: result.stderr)
  }

  /// `ffmpeg -i <file>`'s own stream banner — probed for "does an audio
  /// stream exist at all", since the bundled FFmpeg has no `ffprobe`.
  private func streamBanner(of file: URL, ffmpeg: URL) async throws -> String {
    let result = try await spawnAndRun(
      executable: ffmpeg, arguments: ["-hide_banner", "-i", file.path],
      workingDirectory: file.deletingLastPathComponent())
    // `-i` alone always exits non-zero (no output requested) — the banner on
    // stderr is what this call is actually after.
    return result.stderr
  }

  // MARK: - Metadata (deliberately not `VideoInfoFetcher`, see `rawInfoOutput`)

  /// Runs the helper's `info` verb and returns raw stdout — deliberately not
  /// `VideoInfoFetcher.fetch`, which also decodes `owner` from the response.
  /// As of this writing, the CLI's `info --format Raw` returns `owner: null`
  /// for *every* VOD checked (this one, the one `videoID` used to name, and
  /// others) — the query it sends for a single video's own metadata is
  /// evidently not the one Twitch's GQL backend still answers with owner
  /// data, independent of which video is asked about. That is a separate,
  /// pre-existing gap in `VideoInfo.parse`'s non-optional `owner` field —
  /// nothing to do with what this branch changes — so this test reads the
  /// one thing it actually needs, the top quality's playlist entry, straight
  /// out of the raw text instead of going through the parser that trips on
  /// it. Uses `Process` directly rather than `spawnAndRun`/`ProcessSpawner`:
  /// those exist for the SIGKILL-timing machinery the real steps below need,
  /// which `info` does not, and `spawnAndRun` does not hand back its raw
  /// stdout anyway (only the `out_time_us=` progress it watches for).
  /// Retried for the same reason `runWithRetry` retries every other verb
  /// below: `info` hits the same intermittently-inconsistent Twitch GQL
  /// backend, and a bad response here can crash the helper outright rather
  /// than merely return odd data.
  private func rawInfoOutput(id: String, helper: URL, attempts: Int = 8) async throws -> String {
    var lastStatus: Int32 = -1
    for attempt in 1 ... attempts {
      let process = Process()
      process.executableURL = helper
      process.arguments = ArgumentBuilder.infoArguments(id: id)
      let stdoutPipe = Pipe()
      process.standardOutput = stdoutPipe
      process.standardError = Pipe()
      try process.run()
      let data = await BlockingThread.run("resume-e2e-info") {
        stdoutPipe.fileHandleForReading.readDataToEndOfFile()
      }
      process.waitUntilExit()
      if process.terminationStatus == 0 {
        if attempt > 1 { print("info fetch succeeded on attempt \(attempt)/\(attempts).") }
        return String(decoding: data, as: UTF8.self)
      }
      lastStatus = process.terminationStatus
      let backoff = min(attempt * 2, 15)
      print("info fetch attempt \(attempt)/\(attempts) exited \(lastStatus) — retrying in \(backoff)s.")
      try await Task.sleep(for: .seconds(backoff))
    }
    throw TestError("info fetch failed after \(attempts) attempts (exit \(lastStatus))")
  }

  /// The first quality in the master playlist — the same selection
  /// `VideoInfo.qualities.first` would make — read directly from the first
  /// `#EXT-X-STREAM-INF:` line's attributes rather than through the full
  /// parser `rawInfoOutput`'s doc comment explains avoiding.
  private func topStreamQuality(in output: String) throws -> StreamQuality {
    let lines = output.split(separator: "\n", omittingEmptySubsequences: false)
    guard let streamInfLine = lines.first(where: { $0.hasPrefix("#EXT-X-STREAM-INF:") })
    else { throw TestError("no #EXT-X-STREAM-INF line in info output:\n\(output.suffix(1000))") }
    let line = String(streamInfLine)
    let resolution = try lastString(matching: #"RESOLUTION=(\d+x\d+)"#, in: line)
    let bandwidth = try lastInt(matching: #"BANDWIDTH=(\d+)"#, in: line)
    let name = (try? lastString(matching: #"STABLE-VARIANT-ID="([^"]+)""#, in: line)) ?? resolution
    return StreamQuality(name: name, resolution: resolution, bitsPerSecond: bandwidth)
  }

  private func lastString(matching pattern: String, in text: String) throws -> String {
    let regex = try NSRegularExpression(pattern: pattern)
    let matches = regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
    guard let last = matches.last, let range = Range(last.range(at: 1), in: text)
    else { throw TestError("no match for /\(pattern)/ in:\n\(text.suffix(2000))") }
    return String(text[range])
  }

  private func lastInt(matching pattern: String, in text: String) throws -> Int {
    let regex = try NSRegularExpression(pattern: pattern)
    let matches = regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
    guard let last = matches.last, let range = Range(last.range(at: 1), in: text),
          let value = Int(text[range])
    else { throw TestError("no match for /\(pattern)/ in:\n\(text.suffix(2000))") }
    return value
  }

  private func lastTimecode(matching pattern: String, in text: String) throws -> Double {
    let regex = try NSRegularExpression(pattern: pattern)
    let matches = regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
    guard let last = matches.last,
          let hRange = Range(last.range(at: 1), in: text), let h = Double(text[hRange]),
          let mRange = Range(last.range(at: 2), in: text), let m = Double(text[mRange]),
          let sRange = Range(last.range(at: 3), in: text), let s = Double(text[sRange])
    else { throw TestError("no match for /\(pattern)/ in:\n\(text.suffix(2000))") }
    return h * 3600 + m * 60 + s
  }

  /// Dumps one frame from `file`, at `seconds`, as raw `yuv420p` — the only
  /// way to compare frames against the bundled FFmpeg, which has neither
  /// `psnr`/`ssim` nor a `png` encoder (resume.md §2.1). `crop` selects just
  /// the video-width portion of a composite frame, which is wider than the
  /// plain source it is being compared against.
  private func extractRawFrame(
    from file: URL, atSeconds position: Double, crop: (width: Int, height: Int)?,
    ffmpeg: URL, to output: URL)
    async throws
  {
    var arguments = [
      "-y", "-loglevel", "error", "-ss", String(format: "%.6f", position),
      "-i", file.path, "-frames:v", "1",
    ]
    if let crop {
      arguments += ["-vf", "crop=\(crop.width):\(crop.height):0:0"]
    }
    arguments += ["-f", "rawvideo", "-pix_fmt", "yuv420p", output.path]
    let result = try await spawnAndRun(
      executable: ffmpeg, arguments: arguments, workingDirectory: output.deletingLastPathComponent())
    guard case .exited(0) = result.status else {
      throw TestError("frame extraction at \(position)s failed (\(result.status)):\n\(result.stderr)")
    }
  }

  /// Mean absolute difference over the luma plane only — the brief's own
  /// method (task-11 brief step 4; resume.md §2 records the reference
  /// numbers: low single digits at correct alignment, ~10+ one frame off).
  private func lumaMAD(_ a: URL, _ b: URL, width: Int, height: Int) throws -> Double {
    let dataA = try Data(contentsOf: a)
    let dataB = try Data(contentsOf: b)
    let count = width * height
    guard dataA.count >= count, dataB.count >= count else {
      throw TestError("raw frame too small: got \(dataA.count)/\(dataB.count) bytes, want >= \(count)")
    }
    var total = 0
    for i in 0 ..< count {
      total += abs(Int(dataA[dataA.startIndex + i]) - Int(dataB[dataB.startIndex + i]))
    }
    return Double(total) / Double(count)
  }

  // MARK: - The run

  @Test func aHardKilledCompositeResumesAndDeliversTheCorrectFile() async throws {
    let helper = try requireBinary("build/helper/TwitchDownloaderCLI")
    let ffmpeg = try requireBinary("build/ffmpeg/ffmpeg")

    let root = URL(filePath: NSTemporaryDirectory())
      .appending(path: "oxbow-resume-e2e-\(UUID().uuidString)")
    let scratch = root.appending(path: "scratch")
    try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let workspace = Workspace(root: root)
    let engine = QueueEngine(configuration: QueueEngine.Configuration(
      helperExecutable: helper,
      ffmpegPath: ffmpeg,
      workspace: workspace,
      // Never read: this test drives `makeContext` directly and never calls
      // `start()`/`enqueue()`, so nothing ever loads or saves through it.
      store: QueueStore(fileURL: root.appending(path: "unused-queue.json")),
      makeProcess: { HelperProcess() }))

    let jobID = JobID(rawValue: UUID())
    let videoStepID = StepID(rawValue: UUID())
    let chatStepID = StepID(rawValue: UUID())
    let renderStepID = StepID(rawValue: UUID())
    let compositeStepID = StepID(rawValue: UUID())
    let assembleStepID = StepID(rawValue: UUID())
    let created = Date()

    // Real metadata, real network — exactly what intake does before a byte
    // is downloaded, short of going through `VideoInfoFetcher` itself; see
    // `rawInfoOutput`'s doc comment for why. The top playlist entry is what
    // an empty (default) quality resolves to for a composite job
    // (compositing.md §4).
    let infoOutput = try await rawInfoOutput(id: Self.videoID, helper: helper)
    let quality = try topStreamQuality(in: infoOutput)
    let geometry = try #require(
      CompositeGeometry(quality: quality), "could not derive geometry from \(quality)")

    let videoRequest = VideoRequest(
      videoID: Self.videoID, quality: quality.commandLineValue,
      trimStart: Self.trimStart, trimEnd: Self.trimEnd)
    let chatRequest = ChatRequest(
      videoID: Self.videoID, trimStart: Self.trimStart, trimEnd: Self.chatTrimEnd, format: .json)
    let renderRequest = RenderRequest(
      width: geometry.chatWidth, height: geometry.videoHeight, framerate: geometry.chatFramerate,
      fontSize: geometry.fontSize(for: .default))
    let compositeRequest = CompositeRequest(
      framerate: geometry.videoFramerate,
      duration: Self.contentDuration,
      destination: scratch.appending(path: "delivered.mp4"))
    let assembleRequest = AssembleRequest(destination: scratch.appending(path: "delivered.mp4"))

    func job(videoArtifact: URL?, chatArtifact: URL?, renderArtifact: URL?, compositeArtifact: URL?) -> Job {
      Job(id: jobID, created: created, title: "resume-e2e", steps: [
        Step(id: videoStepID, kind: .downloadVideo(videoRequest),
             status: videoArtifact != nil ? .done : .queued, artifact: videoArtifact),
        Step(id: chatStepID, kind: .downloadChat(chatRequest),
             status: chatArtifact != nil ? .done : .queued, artifact: chatArtifact),
        Step(id: renderStepID, kind: .renderChat(renderRequest),
             status: renderArtifact != nil ? .done : .queued,
             dependsOn: [chatStepID], artifact: renderArtifact),
        Step(id: compositeStepID, kind: .composite(compositeRequest),
             status: compositeArtifact != nil ? .done : .queued,
             dependsOn: [videoStepID, renderStepID], artifact: compositeArtifact),
        Step(id: assembleStepID, kind: .assemble(assembleRequest), dependsOn: [compositeStepID]),
      ])
    }

    // MARK: Attempt 1 — real download, real render, real (interrupted) composite

    var snapshot = job(videoArtifact: nil, chatArtifact: nil, renderArtifact: nil, compositeArtifact: nil)
    let video1Context = try engine.makeContext(job: snapshot, step: snapshot.steps[0])
    try await runWithRetry(.downloadVideo(videoRequest), context: video1Context, executable: helper, label: "attempt 1 video download")
    let video1 = video1Context.outputFile
    try #require(FileManager.default.fileExists(atPath: video1.path))

    snapshot = job(videoArtifact: video1, chatArtifact: nil, renderArtifact: nil, compositeArtifact: nil)
    let chat1Context = try engine.makeContext(job: snapshot, step: snapshot.steps[1])
    try await runWithRetry(.downloadChat(chatRequest), context: chat1Context, executable: helper, label: "attempt 1 chat download")
    let chat1 = chat1Context.outputFile
    try #require(FileManager.default.fileExists(atPath: chat1.path))

    snapshot = job(videoArtifact: video1, chatArtifact: chat1, renderArtifact: nil, compositeArtifact: nil)
    let render1Context = try engine.makeContext(job: snapshot, step: snapshot.steps[2])
    try await runWithRetry(.renderChat(renderRequest), context: render1Context, executable: helper, label: "attempt 1 chat render")
    let render1 = render1Context.outputFile
    try #require(FileManager.default.fileExists(atPath: render1.path))

    snapshot = job(videoArtifact: video1, chatArtifact: chat1, renderArtifact: render1, compositeArtifact: nil)
    let composite1Context = try engine.makeContext(job: snapshot, step: snapshot.steps[3])
    #expect(composite1Context.resumeFrom == nil, "a first attempt must not seek")
    #expect(composite1Context.outputFile.lastPathComponent == "piece-0.mp4")
    #expect(
      composite1Context.outputFile.deletingLastPathComponent().path
        == workspace.resumeDirectory(jobID).path,
      "a piece must live in the retention area, not the job workspace — resume.md §3")

    let killThresholdMicros = Int(seconds(Self.contentDuration) * Self.killFraction * 1_000_000)
    let attempt1Start = ContinuousClock.now
    let attempt1 = try await run(
      .composite(compositeRequest), context: composite1Context, executable: ffmpeg,
      killAfterMicros: killThresholdMicros)
    let attempt1Elapsed = ContinuousClock.now - attempt1Start

    try #require(
      attempt1.killedAtMicros != nil,
      Comment(rawValue: "the kill threshold was never reached — the composite finished before "
        + "it could be interrupted; this run does not test what it claims to"))
    print("Attempt 1: killed by SIGKILL at out_time_us=\(attempt1.killedAtMicros!) "
      + "(\(seconds(Self.contentDuration) * Self.killFraction)s target), "
      + "wall clock \(attempt1Elapsed)")

    // MARK: The piece survives a genuine crash

    let piece0 = composite1Context.outputFile
    let piece0SizeBefore = try FileManager.default.attributesOfItem(atPath: piece0.path)[.size] as? Int ?? 0
    try #require(piece0SizeBefore > 0, "a hard-killed composite left no usable partial piece")

    let piece0IndexBeforeRepair = try FragmentedMP4.index(of: piece0)
    print("Piece 0 before repair: \(piece0SizeBefore) bytes, "
      + "\(piece0IndexBeforeRepair.frameCount) complete frames, "
      + "\(piece0IndexBeforeRepair.completeBytes) usable bytes")

    // MARK: Simulate a relaunch: sweep `jobs/`, never touch `resume/`

    workspace.removeAll()
    #expect(!FileManager.default.fileExists(atPath: workspace.jobDirectory(jobID).path),
            "the launch sweep must clear the jobs/ tree")
    #expect(FileManager.default.fileExists(atPath: piece0.path),
            "the retained piece must survive the launch sweep — resume.md §3")

    // MARK: The sidecar left behind by the hard kill is genuinely corrupt

    // `audio.m4a` is written by the *same* FFmpeg invocation as piece 0, as a
    // second, ordinary (non-fragmented) output — see `ArgumentBuilder`'s
    // `.composite` case. Only the piece carries
    // `-movflags +frag_keyframe+empty_moov+…`; the sidecar does not, so
    // killing the process that is still writing it — exactly what just
    // happened above, and exactly the scenario resume exists for — leaves it
    // with no `moov` at all. This is the defect docs/design/resume.md §4
    // records; what follows is whether the next composite attempt notices
    // and repairs it.
    let audioSidecar = workspace.resumeDirectory(jobID).appending(path: "audio.m4a")
    let corruptSize = try FileManager.default.attributesOfItem(atPath: audioSidecar.path)[.size] as? Int ?? -1
    let corruptBanner = try await streamBanner(of: audioSidecar, ffmpeg: ffmpeg)
    let corruptIsReadable = corruptBanner.contains("Stream #")
    let corruptHasMoov = try FragmentedMP4.hasCompleteMoov(at: audioSidecar)
    print("Audio sidecar after the hard kill: \(corruptSize) bytes, "
      + "readable=\(corruptIsReadable), hasCompleteMoov=\(corruptHasMoov)")
    #expect(
      !corruptIsReadable && !corruptHasMoov,
      Comment(rawValue: "setup check, not the fix under test: the hard kill above must leave a "
        + "genuinely unusable sidecar, or nothing below proves anything"))

    // MARK: Attempt 2 — real re-download (retry re-fetches everything the sweep took), real resumed composite

    snapshot = job(videoArtifact: nil, chatArtifact: nil, renderArtifact: nil, compositeArtifact: nil)
    let video2Context = try engine.makeContext(job: snapshot, step: snapshot.steps[0])
    try await runWithRetry(.downloadVideo(videoRequest), context: video2Context, executable: helper, label: "attempt 2 video download")
    let video2 = video2Context.outputFile
    try #require(FileManager.default.fileExists(atPath: video2.path))

    let video1Size = try FileManager.default.attributesOfItem(atPath: video1.path)[.size] as? Int ?? -1
    let video2Size = try FileManager.default.attributesOfItem(atPath: video2.path)[.size] as? Int ?? -2
    print("Re-download determinism: attempt 1 video \(video1Size)B, attempt 2 video \(video2Size)B")

    snapshot = job(videoArtifact: video2, chatArtifact: nil, renderArtifact: nil, compositeArtifact: nil)
    let chat2Context = try engine.makeContext(job: snapshot, step: snapshot.steps[1])
    try await runWithRetry(.downloadChat(chatRequest), context: chat2Context, executable: helper, label: "attempt 2 chat download")
    let chat2 = chat2Context.outputFile

    snapshot = job(videoArtifact: video2, chatArtifact: chat2, renderArtifact: nil, compositeArtifact: nil)
    let render2Context = try engine.makeContext(job: snapshot, step: snapshot.steps[2])
    try await runWithRetry(.renderChat(renderRequest), context: render2Context, executable: helper, label: "attempt 2 chat render")
    let render2 = render2Context.outputFile

    snapshot = job(videoArtifact: video2, chatArtifact: chat2, renderArtifact: render2, compositeArtifact: nil)
    let composite2Context = try engine.makeContext(job: snapshot, step: snapshot.steps[3])

    let resumeFrom = try #require(
      composite2Context.resumeFrom, "the second attempt did not see the retained piece and resume")
    let seam = seconds(resumeFrom)
    #expect(composite2Context.outputFile.lastPathComponent == "piece-1.mp4")

    let attempt2Arguments = ArgumentBuilder.arguments(
      for: .composite(compositeRequest), context: composite2Context)
    #expect(attempt2Arguments.contains("-ss"), "a resumed composite's argv must carry -ss")
    let ssIndex = try #require(attempt2Arguments.firstIndex(of: "-ss"))
    let ssValue = try #require(Double(attempt2Arguments[ssIndex + 1]))
    #expect(ssValue > 0, "the resume seek must be non-zero")

    // The kill landed partway, so a meaningful prefix and a meaningful tail
    // must both exist — not "resumed from 0.01s" or "resumed from the end".
    let totalContentSeconds = seconds(Self.contentDuration)
    #expect(seam > 5, "too little survived the kill to be a meaningful test (seam \(seam)s)")
    #expect(seam < totalContentSeconds - 5,
            "too little tail remained to be a meaningful test (seam \(seam)s of \(totalContentSeconds)s)")

    // MARK: THE FIX — a resumed composite must notice the corrupt sidecar and rewrite it

    // `resumeFrom` is non-nil here (this is a resume), so the old gate
    // (`resumeFrom == nil`) would have skipped the sidecar entirely — the
    // exact defect this branch fixes. The new gate is usability, computed by
    // `QueueEngine.makeContext` from the real file on disk above.
    #expect(
      !composite2Context.hasUsableSidecar,
      "the corrupt sidecar left by attempt 1 must not be reported usable to a resumed attempt")

    #expect(attempt2Arguments.contains("2:a:0?"),
            "a resumed attempt with no usable sidecar must map its audio from a third input")
    #expect(!attempt2Arguments.contains("0:a:0?"),
            "input 0 is seeked on a resume — mapping from it would truncate the sidecar to the tail")
    let attempt2InputIndices = attempt2Arguments.indices.filter { attempt2Arguments[$0] == "-i" }
    #expect(attempt2InputIndices.count == 3,
            "video (seeked), chat (seeked), and a third un-seeked copy of the video for the sidecar")
    if attempt2InputIndices.count == 3 {
      #expect(attempt2Arguments[attempt2InputIndices[0] + 1] == video2.path)
      #expect(attempt2Arguments[attempt2InputIndices[1] + 1] == render2.path)
      #expect(attempt2Arguments[attempt2InputIndices[2] + 1] == video2.path,
              "the third input must be the same source video, un-seeked, not a different file")
      #expect(attempt2Arguments[attempt2InputIndices[2] - 1] != "-ss",
              "the third input must be un-seeked, or it would capture only the tail too")
    }

    // The chat render is shorter than the video here — 5s against 120s —
    // which is not an artefact of this test's narrow chat window but the
    // ordinary case it stands in for: renders end at the last message, so a
    // stream that goes quiet before it ends produces one. Seeking that render
    // to the video's resume point lands past its end, yields zero frames, and
    // `hstack` has no last frame to repeat — the composite then writes an
    // empty piece and exits 0. `makeContext` clamps the chat's seek for
    // exactly this case; without the clamp, piece 1 below comes out with one
    // frame in it and the delivery is truncated at the seam. resume.md §12.
    let renderLength = try #require(try FragmentedMP4.duration(of: render2))
    let chatSeek = try #require(composite2Context.chatResumeFrom)
    print("Chat render runs \(seconds(renderLength))s against \(totalContentSeconds)s of video; "
      + "video seeks to \(seam)s, chat to \(seconds(chatSeek))s")
    #expect(chatSeek < renderLength,
            "the chat's seek must land inside its own render, or the graph yields nothing")
    #expect(seam > seconds(renderLength),
            "this test only exercises the clamp while the resume point is past the render's end")

    let attempt2Start = ContinuousClock.now
    let attempt2 = try await run(.composite(compositeRequest), context: composite2Context, executable: ffmpeg)
    let attempt2Elapsed = ContinuousClock.now - attempt2Start
    guard case .exited(0) = attempt2.status else {
      throw TestError("resumed composite failed (\(attempt2.status)):\n\(attempt2.stderr)")
    }
    let piece1 = composite2Context.outputFile
    try #require(FileManager.default.fileExists(atPath: piece1.path))

    // MARK: The sidecar is now valid, and covers the whole content window — not just the tail

    let fixedSize = try FileManager.default.attributesOfItem(atPath: audioSidecar.path)[.size] as? Int ?? -1
    let fixedBanner = try await streamBanner(of: audioSidecar, ffmpeg: ffmpeg)
    let fixedIsReadable = fixedBanner.contains("Stream #")
    let fixedHasMoov = try FragmentedMP4.hasCompleteMoov(at: audioSidecar)
    print("Audio sidecar after the resumed attempt rewrote it: \(fixedSize) bytes, "
      + "readable=\(fixedIsReadable), hasCompleteMoov=\(fixedHasMoov)")
    #expect(fixedIsReadable && fixedHasMoov,
            "the resumed attempt must leave a playable sidecar behind — this is the fix")

    let sidecarFinalTime = try await finalTime(of: audioSidecar, extraArgs: [], ffmpeg: ffmpeg)
    print("Rewritten sidecar runs to \(sidecarFinalTime)s of \(totalContentSeconds)s content")
    #expect(sidecarFinalTime > totalContentSeconds - 1,
            Comment(rawValue: "the rewrite must supply the FULL track from the un-seeked third "
              + "input, not just the tail — a sidecar truncated to the tail would be worse than "
              + "the original corruption, since it would desync silently instead of failing loudly"))

    print("Attempt 2: resumed from \(seam)s of \(totalContentSeconds)s, "
      + "wall clock \(attempt2Elapsed) (attempt 1 ran \(attempt1Elapsed) before being killed)")
    #expect(attempt2Elapsed < attempt1Elapsed,
            Comment(rawValue: "a resumed attempt encoding only the tail must run for less wall "
              + "clock than the killed attempt spent on a larger prefix"))

    // MARK: Reference — a straight-through composite of the same range, from the same (attempt 2) inputs

    let referenceContext = StepContext(
      stepTempDirectory: scratch,
      outputFile: scratch.appending(path: "reference.mp4"),
      ffmpegPath: ffmpeg,
      inputArtifacts: [video2, render2],
      resumeFrom: nil)
    let referenceStart = ContinuousClock.now
    let reference = try await run(.composite(compositeRequest), context: referenceContext, executable: ffmpeg)
    let referenceElapsed = ContinuousClock.now - referenceStart
    guard case .exited(0) = reference.status else {
      throw TestError("reference composite failed (\(reference.status)):\n\(reference.stderr)")
    }
    print("Reference (straight-through, same inputs): wall clock \(referenceElapsed)")

    // MARK: A video-only measurement assembly (see the audio finding below for why this is separate from `.assemble`)

    let pieces = [piece0, piece1]
    let piecesList = pieces.map { "file '\($0.path)'" }.joined(separator: "\n") + "\n"
    let piecesListFile = scratch.appending(path: "measured-pieces.txt")
    try piecesList.write(to: piecesListFile, atomically: true, encoding: .utf8)
    let measured = scratch.appending(path: "measured.mp4")
    let measureResult = try await spawnAndRun(
      executable: ffmpeg,
      arguments: [
        "-nostdin", "-y", "-hide_banner", "-loglevel", "error",
        "-f", "concat", "-safe", "0", "-i", piecesListFile.path,
        "-map", "0:v:0", "-c", "copy", measured.path,
      ],
      workingDirectory: scratch)
    guard case .exited(0) = measureResult.status else {
      throw TestError("video-only concat failed (\(measureResult.status)):\n\(measureResult.stderr)")
    }

    // MARK: Frame count: delivered must be within a couple of frames of a straight-through encode

    let deliveredFrames = try await frameCount(of: measured, ffmpeg: ffmpeg)
    let referenceFrames = try await frameCount(of: referenceContext.outputFile, ffmpeg: ffmpeg)
    let piece0Frames = try FragmentedMP4.index(of: piece0).frameCount
    let piece1Frames = try FragmentedMP4.index(of: piece1).frameCount
    print("Frame counts: piece 0 = \(piece0Frames), piece 1 = \(piece1Frames), "
      + "sum = \(piece0Frames + piece1Frames); delivered (concat) = \(deliveredFrames); "
      + "reference (straight-through) = \(referenceFrames)")
    #expect(piece0Frames + piece1Frames == deliveredFrames,
            "the two pieces' frame counts must sum to the assembled file's")

    // Not exact equality. Measured on a real run: delivered 3603 vs reference
    // 3601 — 2 frames (0.055%), consistently on the resumed side. Chased
    // down rather than waved away: decoding `video2` alone (no compositing)
    // splits perfectly at the seek point — 2262 (0–76.4s) + 1310
    // (76.4s–end) = 3572, the same as one continuous decode — so this is not
    // a seek-accuracy bug (resume.md §2.1's own concern). The composite's
    // CFR gap-fill (resume.md §2: "the source holds 5998 frames across 200s
    // where the composite emits 6001") is computed from each piece's own
    // `setpts=PTS-STARTPTS` zero point, independently — so splitting the
    // timeline can shift where a fill decision lands relative to one
    // continuous pass, the same way splitting a sum changes floating-point
    // rounding. The seam MAD below is what actually rules out lost or
    // duplicated *content*; this tolerance only accepts that a resumed
    // delivery's total length is not bit-for-bit identical to a from-scratch
    // encode, which resume.md does not currently say.
    #expect(abs(deliveredFrames - referenceFrames) <= 3,
            Comment(rawValue: "delivered (\(deliveredFrames)) and reference (\(referenceFrames)) "
              + "frame counts diverged by more than the measured CFR-boundary tolerance"))

    // MARK: Seam check — by timestamp, never by frame index (resume.md §2.1)

    let gotSeam = scratch.appending(path: "got_seam.raw")
    let wantSeam = scratch.appending(path: "want_seam.raw")
    try await extractRawFrame(
      from: measured, atSeconds: seam, crop: (geometry.videoWidth, geometry.videoHeight),
      ffmpeg: ffmpeg, to: gotSeam)
    try await extractRawFrame(
      from: video2, atSeconds: seam, crop: nil, ffmpeg: ffmpeg, to: wantSeam)
    let seamMAD = try lumaMAD(gotSeam, wantSeam, width: geometry.videoWidth, height: geometry.videoHeight)

    let frameInterval = 1.0 / Double(geometry.videoFramerate)
    let gotNeighbour = scratch.appending(path: "got_neighbour.raw")
    try await extractRawFrame(
      from: video2, atSeconds: seam + frameInterval, crop: nil, ffmpeg: ffmpeg, to: gotNeighbour)
    let neighbourMAD = try lumaMAD(
      gotSeam, gotNeighbour, width: geometry.videoWidth, height: geometry.videoHeight)

    print("Seam MAD at \(seam)s: \(seamMAD) (correct alignment); "
      + "one frame off (\(seam + frameInterval)s): \(neighbourMAD) (should be clearly higher)")
    #expect(seamMAD < 5, "seam frame should match the source closely (compression noise only)")
    #expect(neighbourMAD > seamMAD + 3,
            Comment(rawValue: "a one-frame offset must score measurably worse, or this "
              + "comparison has no discriminating power — resume.md §2.1"))

    // MARK: Audio: completeness and sync, as an independent control on assemble's own mechanism
    //
    // The real sidecar is valid at this point (the fix above rewrote it), and
    // is checked directly against the real `.assemble` step further down.
    // This block is an independent control: it exercises the same concat +
    // audio-mapping mechanism `.assemble` uses, but against a *freshly
    // extracted* audio copy that never depended on the fix at all — so a
    // failure below can be attributed to assemble's own approach rather than
    // to whether the sidecar rewrite worked. Extracted from `video2` before
    // assemble's `makeContext` call deletes it.
    let freshAudio = scratch.appending(path: "fresh_audio.m4a")
    let extractAudio = try await spawnAndRun(
      executable: ffmpeg,
      arguments: [
        "-nostdin", "-y", "-hide_banner", "-loglevel", "error",
        "-i", video2.path, "-map", "0:a:0?", "-c:a", "copy", freshAudio.path,
      ],
      workingDirectory: scratch)
    guard case .exited(0) = extractAudio.status else {
      throw TestError("fresh audio extraction failed (\(extractAudio.status)):\n\(extractAudio.stderr)")
    }

    let hypotheticalDelivery = scratch.appending(path: "hypothetical_delivery.mp4")
    let hypotheticalAssemble = try await spawnAndRun(
      executable: ffmpeg,
      arguments: [
        "-nostdin", "-y", "-hide_banner", "-loglevel", "error",
        "-f", "concat", "-safe", "0", "-i", piecesListFile.path,
        "-i", freshAudio.path,
        "-map", "0:v:0", "-map", "1:a:0?", "-c", "copy",
        hypotheticalDelivery.path,
      ],
      workingDirectory: scratch)
    guard case .exited(0) = hypotheticalAssemble.status else {
      throw TestError(
        "hypothetical assemble (valid audio) failed (\(hypotheticalAssemble.status)):"
          + "\n\(hypotheticalAssemble.stderr)")
    }

    let hypotheticalBanner = try await streamBanner(of: hypotheticalDelivery, ffmpeg: ffmpeg)
    #expect(hypotheticalBanner.contains("Audio:"), "the assembled file must carry an audio stream")

    let videoFinalTime = try await finalTime(of: hypotheticalDelivery, extraArgs: ["-an"], ffmpeg: ffmpeg)
    let audioFinalTime = try await finalTime(of: hypotheticalDelivery, extraArgs: ["-vn"], ffmpeg: ffmpeg)
    print("With a valid audio track, assemble's own mechanism: video runs to \(videoFinalTime)s, "
      + "audio runs to \(audioFinalTime)s (content window \(totalContentSeconds)s)")
    #expect(videoFinalTime > totalContentSeconds - 1,
            "the delivered video must run to the end of the content window")
    #expect(abs(videoFinalTime - audioFinalTime) < 0.5,
            Comment(rawValue: "audio must stay in sync with video to the end — they should "
              + "finish within one AAC frame of each other"))

    // MARK: The real `.assemble` step, run exactly as `QueueEngine` would — now expected to succeed

    snapshot = job(
      videoArtifact: video2, chatArtifact: chat2, renderArtifact: render2, compositeArtifact: piece1)
    let assembleContext = try engine.makeContext(job: snapshot, step: snapshot.steps[4])

    // `makeContext`'s own side effect: the re-fetched video and render are
    // deleted the moment the assemble context is built, regardless of
    // whether the ffmpeg invocation that follows can actually succeed —
    // resume.md §5 step 5.
    #expect(!FileManager.default.fileExists(atPath: video2.path),
            "assemble must delete the re-fetched video — resume.md §5")
    #expect(!FileManager.default.fileExists(atPath: render2.path),
            "assemble must delete the re-fetched render — resume.md §5")

    let assembleResult = try await run(.assemble(assembleRequest), context: assembleContext, executable: ffmpeg)
    print("Real `.assemble` step exit status: \(assembleResult.status)")
    guard case .exited(0) = assembleResult.status else {
      throw TestError(
        "`.assemble` failed even after the resumed composite rewrote the sidecar — the fix did "
          + "not close the gap it was meant to (\(assembleResult.status)):\n"
          + "\(assembleResult.stderr.suffix(2000))")
    }
    print("`.assemble` succeeded, using the sidecar the resumed composite rewrote — a hard-killed "
      + "first attempt now recovers, which is the whole point of this branch.")

    // MARK: The delivered file itself has audio, and it runs in sync to the end

    let delivered = assembleContext.outputFile
    try #require(FileManager.default.fileExists(atPath: delivered.path))
    let deliveredBanner = try await streamBanner(of: delivered, ffmpeg: ffmpeg)
    #expect(deliveredBanner.contains("Audio:"), "the assembled file must carry an audio stream")

    let deliveredVideoTime = try await finalTime(of: delivered, extraArgs: ["-an"], ffmpeg: ffmpeg)
    let deliveredAudioTime = try await finalTime(of: delivered, extraArgs: ["-vn"], ffmpeg: ffmpeg)
    print("Delivered file: video runs to \(deliveredVideoTime)s, audio runs to "
      + "\(deliveredAudioTime)s (content window \(totalContentSeconds)s)")
    #expect(deliveredVideoTime > totalContentSeconds - 1,
            "the delivered video must run to the end of the content window")
    #expect(abs(deliveredVideoTime - deliveredAudioTime) < 0.5,
            Comment(rawValue: "audio must stay in sync with video to the end. This is the actual "
              + "end-to-end claim: a hard-killed first attempt, once resumed, delivers a file with "
              + "correct, complete audio — not a job stuck failing at .assemble forever."))

    print("""

      ================ SUMMARY ================
      Content window: \(totalContentSeconds)s
      Attempt 1 (killed): out_time_us=\(attempt1.killedAtMicros!), wall clock \(attempt1Elapsed)
      Piece 0: \(piece0SizeBefore)B, \(piece0IndexBeforeRepair.frameCount) frames before repair, \(piece0Frames) after
      Sidecar after the kill: \(corruptSize)B, readable=\(corruptIsReadable), hasCompleteMoov=\(corruptHasMoov)
      Attempt 2 (resumed): seam \(seam)s, -ss \(ssValue), wall clock \(attempt2Elapsed)
      Sidecar after the fix rewrote it: \(fixedSize)B, readable=\(fixedIsReadable), runs to \(sidecarFinalTime)s
      Piece 1: \(piece1Frames) frames
      Reference (straight-through): wall clock \(referenceElapsed), \(referenceFrames) frames
      Delivered (video-only concat, measurement only): \(deliveredFrames) frames
      Seam MAD: \(seamMAD) (aligned) vs \(neighbourMAD) (one frame off)
      Re-download determinism: attempt 1 video \(video1Size)B, attempt 2 video \(video2Size)B
      Real `.assemble` exit status: \(assembleResult.status)
      Delivered file: video \(deliveredVideoTime)s, audio \(deliveredAudioTime)s
      ===========================================
      """)
  }
}
