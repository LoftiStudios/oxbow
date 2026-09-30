import Darwin
import Foundation
import Synchronization

/// A chat render step run natively rather than through the CLI: the same input file, the same
/// output file, the same encoder settings. It speaks the engine's `HelperProcessing`, so the
/// queue, progress, logs and cancellation treat it as any other step.
/// docs/design/native-chat-render.md §6, phase 1 slice 4.
///
/// Frames are drawn here and piped raw into our own FFmpeg, which encodes exactly as
/// `ArgumentBuilder` asks the CLI's FFmpeg to.
public actor NativeChatRenderProcess: HelperProcessing {
  private let request: RenderRequest
  private let input: URL
  private let output: URL
  private let ffmpeg: URL

  private var encoder: pid_t?
  /// Read by the frame-writing thread between frames.
  private let stop = StopFlag()

  /// Shared by reference with the writer thread, which a non-copyable `Atomic` cannot be.
  private final class StopFlag: Sendable {
    private let value = Atomic<Bool>(false)
    var isSet: Bool { value.load(ordering: .relaxed) }
    func set() { value.store(true, ordering: .relaxed) }
  }

  /// The native renderer for this render, or nil to run the CLI. Native only when it is wanted
  /// and the render reads a chat file with its images embedded: it draws emotes and badges from
  /// those alone, so a render queued before downloads embedded them would lose every emote.
  public static func forRender(
    _ request: RenderRequest, context: StepContext, isEnabled: Bool) -> NativeChatRenderProcess?
  {
    guard isEnabled, request.isOffline, let input = context.inputArtifacts.first else { return nil }
    return NativeChatRenderProcess(
      request: request, input: input, output: context.outputFile, ffmpeg: context.ffmpegPath)
  }

  public init(request: RenderRequest, input: URL, output: URL, ffmpeg: URL) {
    self.request = request
    self.input = input
    self.output = output
    self.ffmpeg = ffmpeg
  }

  /// FFmpeg's arguments for reading raw frames of this geometry and encoding them the way the CLI
  /// is asked to: VideoToolbox at the requested bitrate, `yuv420p`, and `unsharp` when sharpened
  /// (never `--sharpening`'s GPL `smartblur`).
  static func encoderArguments(for request: RenderRequest, output: URL) -> [String] {
    var arguments = [
      "-hide_banner", "-loglevel", "error", "-y",
      "-f", "rawvideo", "-pix_fmt", "rgba",
      "-video_size", "\(request.width)x\(request.height)",
      "-framerate", "\(request.framerate)",
      "-i", "-",
    ]
    if request.isSharpened {
      arguments += ["-vf", "unsharp=5:5:1.0"]
    }
    arguments += [
      "-c:v", "h264_videotoolbox", "-b:v", "\(request.bitrateMbps)M", "-pix_fmt", "yuv420p",
      output.path,
    ]
    return arguments
  }

  public func run(
    _ launch: Launch,
    onOutput: @escaping @Sendable (ParsedLine) async -> Void)
    async throws -> RunResult
  {
    guard !stop.isSet else {
      return RunResult(status: .signalled(SIGKILL), standardError: "")
    }

    // The CLI's own phase names, so the step's progress bar fills the same two segments.
    await onOutput(.log(level: .info, message: "Rendering chat natively (docs/design/native-chat-render.md)"))
    await onOutput(.status(StepProgress(phase: "Fetching Images", fraction: 0)))
    let request = request
    let input = input
    let renderer: NativeChatRenderer
    do {
      renderer = try await BlockingThread.run("oxbow.native-chat-decode") {
        Result { NativeChatRenderer(document: try ChatDocument.decode(from: Data(contentsOf: input)), request: request) }
      }.get()
    } catch {
      return RunResult(status: .exited(1), standardError: "Could not read the chat file: \(error)")
    }
    await onOutput(.status(StepProgress(phase: "Fetching Images", fraction: 1)))

    let spawned = try ProcessSpawner.spawn(
      executable: ffmpeg,
      arguments: Self.encoderArguments(for: request, output: output),
      workingDirectory: launch.workingDirectory,
      standardInput: true)
    encoder = spawned.pid
    if stop.isSet {
      ProcessSpawner.signal(SIGKILL, toGroupOf: spawned.pid)
    }

    // FFmpeg's stderr must be drained while it runs, or a full pipe stalls it and the writer.
    let stderr = spawned.stderr
    let standardError = Task.detached {
      await BlockingThread.run("oxbow.native-chat-stderr") { () -> String in
        String(decoding: stderr.readDataToEndOfFile(), as: UTF8.self)
      }
    }
    let stdout = spawned.stdout
    Task.detached { _ = stdout.readDataToEndOfFile() }

    let progress = AsyncStream<StepProgress> { continuation in
      let stdin = spawned.stdin
      let stop = self.stop
      let thread = Thread {
        Self.writeFrames(of: renderer, to: stdin, stop: stop) { continuation.yield($0) }
        try? stdin?.close()
        continuation.finish()
      }
      thread.name = "oxbow.native-chat-frames"
      thread.start()
    }
    for await update in progress {
      await onOutput(.status(update))
    }

    let pid = spawned.pid
    let status = await BlockingThread.run("oxbow.native-chat-waitpid") { ProcessSpawner.wait(pid) }
    encoder = nil
    return RunResult(status: status, standardError: await standardError.value)
  }

  /// Draws every frame and writes it, reusing the last frame's bytes while the picture has not
  /// changed. Blocking: runs on its own thread.
  private static func writeFrames(
    of renderer: NativeChatRenderer, to stdin: FileHandle?, stop: StopFlag,
    report: (StepProgress) -> Void)
  {
    guard let stdin else { return }
    let clock = ContinuousClock()
    let started = clock.now
    let total = renderer.frameCount
    var lastKey: NativeChatRenderer.FrameKey?
    var bytes = Data()
    for index in 0..<total {
      if stop.isSet { return }
      let key = renderer.contentKey(forFrame: index)
      if key != lastKey {
        bytes = renderer.rgba(frame: index)
        lastKey = key
      }
      // A closed pipe — FFmpeg gone — ends the render; the exit status says why.
      guard (try? stdin.write(contentsOf: bytes)) != nil else { return }
      if index % 30 == 0 || index == total - 1 {
        let fraction = Double(index + 1) / Double(total)
        let elapsed = clock.now - started
        report(StepProgress(
          phase: "Rendering Video", fraction: fraction, elapsed: elapsed,
          remaining: fraction > 0 ? elapsed * ((1 - fraction) / fraction) : nil))
      }
    }
  }

  /// As `HelperProcess` cancels: stop drawing, then SIGTERM so FFmpeg can close the file, then
  /// SIGKILL after a grace period.
  public func cancel() async {
    stop.set()
    guard let pid = encoder else { return }
    ProcessSpawner.signal(SIGTERM, toGroupOf: pid)
    try? await Task.detached { try await Task.sleep(for: .seconds(2)) }.value
    guard encoder == pid else { return }
    ProcessSpawner.signal(SIGKILL, toGroupOf: pid)
  }
}
