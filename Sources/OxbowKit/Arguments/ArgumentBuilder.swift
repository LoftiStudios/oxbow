import Foundation

/// Turns a step into an argv array. Pure, so the CLI's invariants are
/// assertions rather than hopes.
///
/// Flag names verified against TwitchDownloaderCLI 1.56.5 `--help`.
public enum ArgumentBuilder {

  /// Always passed. The default is `Prompt`, which on a name collision blocks
  /// reading a stdin that never arrives — a subprocess hung forever with no
  /// output. We write into our own workspace, so overwriting is always safe.
  private static let collision = ["--collision", "Overwrite"]

  /// An empty quality means "best available": the CLI picks when `-q` is
  /// absent, and passing `-q ""` is not the same thing.
  private static func quality(_ value: String) -> [String] {
    value.isEmpty ? [] : ["-q", value]
  }

  /// Argv for `VideoInfoFetcher`, which runs outside the queue at intake —
  /// there is no `StepKind` for it and never should be (docs/design/
  /// chat-and-render.md §3).
  ///
  /// `--format Raw` because `--format json` throws `NotImplementedException`
  /// upstream; see `VideoInfo`.
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

      // Upstream declares these nine options as switches, not as
      // `--flag=value` options: the parser reads mere *presence* as true and
      // ignores any value that follows, so both `--timestamp=false` and
      // `--timestamp false` turn timestamps ON. Verified against the bundled
      // 1.56.5 helper on 2026-08-25 by extracting frames from paired
      // `=false`/`=true` renders and hashing them: `--timestamp=false` and
      // `--timestamp=true` produced byte-identical frames (sha256
      // `d9b7fea7be2a10be…`), differing only from omitting the flag entirely
      // (`6a2b525002429b03…`); same result for `--outline` (`735d58632d7ada2c…`
      // identical, `53952cd96edf2289…` when omitted). There is no way to pass
      // `false` through this CLI — omitting the flag is the only way to get
      // it. `--banner` is a genuine exception: it is declared differently
      // upstream and its `=false` form really does suppress the banner
      // (verified separately) — that flag is untouched, above.
      //
      // Three of the nine default to false and are therefore fully
      // expressible: emit the bare flag when true, omit it when false.
      // Without `--alternate-backgrounds`, `--alt-background-color` is
      // documented by the CLI as inert.
      if request.hasAlternateBackgrounds { args += ["--alternate-backgrounds"] }
      if request.hasTimestamps { args += ["--timestamp"] }
      if request.hasOutline { args += ["--outline"] }

      // The other six (`--badges`, `--sub-messages`, `--bttv`, `--ffz`,
      // `--stv`, `--allow-unlisted-emotes`) default to true and, per the
      // above, cannot be turned off through this CLI at all — so
      // `RenderRequest` carries no fields for them and nothing is emitted
      // here. A settable field that can never take effect is a lie.

      // The CLI's default is `-c:v libx264`, which is GPL and absent from our
      // LGPL FFmpeg. VideoToolbox is bitrate-targeted; there is no CRF.
      //
      // The equals form is required: a value beginning with `-` is otherwise
      // parsed as more options.
      args += ["--output-args=-c:v h264_videotoolbox -b:v \(request.bitrateMbps)M "
        + "-pix_fmt yuv420p \"{save_path}\""]

      if request.isSharpened {
        // NOT `--sharpening`: that appends smartblur, which configure declares
        // gpl-only and which our build therefore lacks. unsharp was relicensed
        // to LGPL and is present.
        //
        // This restates the CLI's default input args because there is no way to
        // append to them. If upstream changes that default, update this too.
        args += ["--input-args=-framerate {fps} -f rawvideo "
          + "-analyzeduration {max_int} -probesize {max_int} "
          + "-pix_fmt {pix_fmt} -video_size {width}x{height} -i - "
          + "-filter_complex \"unsharp=5:5:1.0\""]
      }
      return args

    case .composite(let request):
      // FFmpeg's own argv, not the CLI's: no verb, no --banner, and the
      // executable is `ffmpegPath` rather than the helper (QueueEngine.launch).
      //
      // Input order is positional and comes from `Step.dependsOn`: [0] is the
      // video, [1] is the chat render.
      let video = request.inputPath(context, at: 0)
      let chat = request.inputPath(context, at: 1)

      // Seconds with six decimals. `frames ÷ framerate` is always ≤ the
      // source's own timestamp for that frame, because Twitch rounds frame
      // times up to whole milliseconds — so the seek lands on the intended
      // frame and never overshoots to the next one. resume.md §2.
      let seek = request.resumeSeek(context.resumeFrom)

      // A second output on the first attempt only. FFmpeg takes any number of
      // outputs per invocation, so the audio copy is free — and it is what
      // lets the downloaded video be deleted before assemble runs, keeping
      // recovery near a normal run's disk peak. A resumed attempt holds only
      // the tail, so re-extracting here would truncate the sidecar to it.
      // resume.md §4.
      //
      // Placed as its own complete output — `-map`/`-c:a`/path — right after
      // both inputs, before the composite's own output options. FFmpeg reads
      // multiple outputs in sequence, each terminated by its path, so this
      // keeps the composite's own file as the argv's final element.
      let sidecar: [String] = context.resumeFrom == nil
        ? ["-map", "0:a:0?", "-c:a", "copy",
           context.outputFile.deletingLastPathComponent()
             .appending(path: "audio.m4a").path]
        : []

      return [
        "-nostdin", "-y", "-hide_banner",
      ] + seek + ["-i", video] + seek + ["-i", chat] + sidecar + [
        "-filter_complex",
        // setpts precedes fps so the rate conversion runs on a zero-based
        // timeline. No `scale` on either input: the chat is rendered at the
        // right size and the video is already native.
        //
        // No `shortest`: chat renders end at the last message, so a quiet
        // final stretch would truncate the VIDEO. hstack's default
        // eof_action=repeat holds the last chat frame instead. Verified.
        "[0:v]setpts=PTS-STARTPTS[v];"
          + "[1:v]setpts=PTS-STARTPTS,fps=\(request.framerate)[c];"
          + "[v][c]hstack=inputs=2[out]",
        "-map", "[out]",
        // Video-only. Audio is mapped once, from the sidecar copied out
        // above — not here, and not again at assemble. A piece carrying its
        // own audio track would double it up for nothing: `.assemble` never
        // reads it (it maps `1:a:0?` from the sidecar), so the copy would
        // just be dead weight in every piece. resume.md §2.
        "-an",
        "-c:v", "h264_videotoolbox",
        "-b:v", "\(request.bitrateMbps)M",
        "-pix_fmt", "yuv420p",
        "-progress", "pipe:1", "-nostats", "-loglevel", "error",
        // empty_moov writes the track declarations with no sample table, so
        // the file is structurally valid from byte 0 — the precondition for
        // resuming at all. frag_keyframe starts a fragment at each keyframe;
        // default_base_moof makes each fragment self-contained. Never
        // +faststart: it rewrites the whole file to relocate the moov atom,
        // which on a 22 GB output is minutes of disk churn for HTTP
        // progressive streaming a local file does not need — and
        // fragmentation makes it meaningless anyway, since there is no
        // monolithic moov to relocate. fragmented-output.md §3.
        "-movflags", "+frag_keyframe+empty_moov+default_base_moof",
        context.outputFile.path,
      ]

    case .assemble:
      // Input 0 is the concat list of pieces; input 1 is the sidecar audio
      // that the composite's first attempt copied out (resume.md §4). The
      // downloaded video is gone by now, and pieces are video-only, so this
      // sidecar is the only audio there is.
      //
      // NOT a byte-append: docs/design/fragmented-output.md §2 measured
      // AVFoundation reading 305 samples of a byte-appended file where FFmpeg
      // reads 901. The concat demuxer produces a correct file; appending
      // bytes does not.
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
        // No +faststart, for the reason in compositing.md §7.
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
