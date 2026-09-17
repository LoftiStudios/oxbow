import Foundation

/// Build argv from a step. Flag names verified against TwitchDownloaderCLI 1.56.5 --help.
public enum ArgumentBuilder {

  /// Prompt would block forever on unavailable stdin after a collision. Outputs are in our
  /// workspace, so always overwrite.
  private static let collision = ["--collision", "Overwrite"]

  /// An empty quality means "best available": the CLI picks when `-q` is
  /// absent, and passing `-q ""` is not the same thing.
  private static func quality(_ value: String) -> [String] {
    value.isEmpty ? [] : ["-q", value]
  }

  /// Metadata argv, outside the queue. Use Raw: upstream's json format throws
  /// NotImplementedException.
  public static func infoArguments(id: String) -> [String] {
    ["info", "--banner=false", "--id", id, "--format", "Raw"]
  }

  public static func arguments(for kind: StepKind, context: StepContext) -> [String] {
    switch kind {
    case .downloadVideo(let request):
      // `--banner=false` is a per-verb option and must follow the verb.
      var args = ["videodownload", "--banner=false"] + collision
      args += ["--id", request.videoID]
      args += quality(request.quality)
      args += ["-o", context.outputFile.path]
      args += ["--temp-path", context.stepTempDirectory.path]
      args += ["--ffmpeg-path", context.ffmpegPath.path]
      args += trim(start: request.trimStart, end: request.trimEnd)
      return args

    case .downloadClip(let request):
      var args = ["clipdownload", "--banner=false"] + collision
      args += ["--id", request.clipSlug]
      args += quality(request.quality)
      args += ["-o", context.outputFile.path]
      args += ["--temp-path", context.stepTempDirectory.path]
      args += ["--ffmpeg-path", context.ffmpegPath.path]
      return args

    case .downloadChat(let request):
      // No --ffmpeg-path: chatdownload never invokes FFmpeg.
      var args = ["chatdownload", "--banner=false"] + collision
      args += ["--id", request.videoID]
      args += ["-o", context.outputFile.path]
      args += ["--temp-path", context.stepTempDirectory.path]
      args += trim(start: request.trimStart, end: request.trimEnd)
      if request.isEmbeddingImages { args += ["-E"] }
      return args

    case .renderChat(let request):
      var args = ["chatrender", "--banner=false"] + collision
      args += ["-i", context.inputArtifacts.first?.path ?? ""]
      args += ["-o", context.outputFile.path]
      args += ["--temp-path", context.stepTempDirectory.path]
      args += ["--ffmpeg-path", context.ffmpegPath.path]
      args += ["-w", String(request.width)]
      args += ["-h", String(request.height)]
      args += ["--framerate", String(request.framerate)]
      args += ["--font-size", String(request.fontSize)]
      args += ["-f", request.font]
      args += ["--background-color", request.backgroundColor]
      args += ["--alt-background-color", request.alternateBackgroundColor]
      args += ["--message-color", request.messageColor]
      args += ["--outline-size", String(request.outlineSize)]

      // Boolean switches are presence-only: =false still enables them (verified with rendered
      // frames). Omit false-default switches to disable; banner=false is a separately declared
      // exception. Always enable dispersion to spread whole-second chat timestamps; it requires
      // update-rate below 1.0, satisfied by upstream's 0.2 default.
      args += ["--dispersion"]

      if request.hasAlternateBackgrounds { args += ["--alternate-backgrounds"] }
      if request.hasTimestamps { args += ["--timestamp"] }
      if request.hasOutline { args += ["--outline"] }

      // These true-default switches cannot be disabled through the CLI: badges, sub-messages,
      // bttv, ffz, stv, allow-unlisted-emotes. Do not expose ineffective request fields.

      // The CLI's default is `-c:v libx264`, which is GPL and absent from our
      // LGPL FFmpeg. VideoToolbox is bitrate-targeted; there is no CRF.
      //
      // The equals form is required: a value beginning with `-` is otherwise
      // parsed as more options.
      args += ["--output-args=-c:v h264_videotoolbox -b:v \(request.bitrateMbps)M "
        + "-pix_fmt yuv420p \"{save_path}\""]

      if request.isSharpened {
        // Use LGPL unsharp, not sharpening's GPL-only smartblur. This replaces the complete
        // upstream input-args default; keep it in sync if that default changes.
        args += ["--input-args=-framerate {fps} -f rawvideo "
          + "-analyzeduration {max_int} -probesize {max_int} "
          + "-pix_fmt {pix_fmt} -video_size {width}x{height} -i - "
          + "-filter_complex \"unsharp=5:5:1.0\""]
      }
      return args

    case .composite(let request):
      // Direct FFmpeg argv. Positional dependencies are [video, chat render].
      let video = request.inputPath(context, at: 0)
      let chat = request.inputPath(context, at: 1)

      // Six-decimal timestamp seek avoids overshooting Twitch's millisecond-rounded frame
      // times; see docs/design/resume.md §2.
      let seek = request.resumeSeek(context.resumeFrom)

      // Clamp short chat inputs inside their end so hstack receives a frame to repeat. A seek
      // beyond the render emits no frames but can exit successfully. Nil means use the video
      // seek.
      let chatSeek = request.resumeSeek(context.chatResumeFrom ?? context.resumeFrom)

      // Rewrite missing or incomplete sidecars on retries too; SIGKILL can leave audio without
      // moov. Checking only first-attempt status would preserve corruption forever.
      let needsSidecar = !context.hasUsableSidecar

      // A resumed input 0 is seeked. Use an additional unseeked source when rewriting the
      // sidecar so it contains full-length audio.
      let needsUnseekedSource = needsSidecar && context.resumeFrom != nil
      let thirdInput: [String] = needsUnseekedSource ? ["-i", video] : []
      let audioInputIndex = needsUnseekedSource ? 2 : 0

      // Emit the complete sidecar output before composite output options; each output path
      // terminates its own FFmpeg option group.
      let sidecar: [String] = needsSidecar
        ? ["-map", "\(audioInputIndex):a:0?", "-c:a", "copy",
           context.outputFile.deletingLastPathComponent()
             .appending(path: "audio.m4a").path]
        : []

      return [
        "-nostdin", "-y", "-hide_banner",
      ] + seek + ["-i", video] + chatSeek + ["-i", chat] + thirdInput + sidecar + [
        "-filter_complex",
        // fps start_time=0 pads an initial video gap while preserving timing relative to
        // untouched sidecar audio. Do not replace it with setpts: stream-copy trims may start
        // video after audio, and rebasing video loses sync. Removing zero-based CFR also caused
        // VideoToolbox failures. Chat starts at zero and keeps setpts before fps. No scaling is
        // needed, and no shortest: hstack repeats the last chat frame through a quiet video
        // tail. See docs/design/composite-quality.md §9 and resume.md §2.
        "[0:v]fps=\(request.framerate):start_time=0[v];"
          + "[1:v]setpts=PTS-STARTPTS,fps=\(request.framerate)[c];"
          + "[v][c]hstack=inputs=2[out]",
        "-map", "[out]",
        // Pieces are video-only; assemble maps audio from the complete sidecar.
        "-an",
        "-c:v", "h264_videotoolbox",
        // Quality 50 adapts to content whose required bitrate spans 7.5x. Never add maxrate:
        // VideoToolbox DataRateLimits displaces quality targeting and measured bitrate rose
        // from 5.0 to 19.3 Mbps with maxrate 30M. See docs/design/composite-rate-control.md
        // §7.1.
        "-q:v", "50",
        "-pix_fmt", "yuv420p",
        "-progress", "pipe:1", "-nostats", "-loglevel", "error",
        // empty_moov supplies track declarations; frag_keyframe and default_base_moof create
        // self-contained resumable fragments. Do not add faststart: fragmented output has no
        // monolithic moov to relocate. See docs/design/fragmented-output.md §3.
        "-movflags", "+frag_keyframe+empty_moov+default_base_moof",
        context.outputFile.path,
      ]

    case .assemble:
      // Input 0 is the concat list; input 1 is sidecar audio. Source video is already removed
      // and pieces are video-only. Use the concat demuxer: byte-appended fragments were not
      // fully readable by AVFoundation (docs/design/fragmented-output.md §2).
      let audio = context.inputArtifacts.first?.path ?? ""
      return [
        "-nostdin", "-y", "-hide_banner",
        "-f", "concat", "-safe", "0",
        "-i", context.stepTempDirectory.appending(path: "pieces.txt").path,
        "-i", audio,
        "-map", "0:v:0",
        "-map", "1:a:0?",
        "-c", "copy",
        "-nostats", "-loglevel", "error",
        // No +faststart, for the reason in compositing.md §5.
        context.outputFile.path,
      ]
    }
  }

  /// The CLI accepts `#ms`, `#s`, `#m`, `#h`, or `##:##:##`. Seconds is the
  /// least ambiguous.
  private static func trim(start: Duration?, end: Duration?) -> [String] {
    var args: [String] = []
    if let start { args += ["-b", "\(start.components.seconds)s"] }
    if let end { args += ["-e", "\(end.components.seconds)s"] }
    return args
  }
}
