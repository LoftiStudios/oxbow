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
      args += ["-i", context.inputArtifact?.path ?? ""]
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
      // Without this, --alt-background-color is documented by the CLI as
      // inert.
      args += ["--alternate-backgrounds=\(request.hasAlternateBackgrounds)"]
      args += ["--message-color", request.messageColor]
      args += ["--outline-size", String(request.outlineSize)]

      // Booleans follow the same single-token `--flag=value` shape already
      // proven by `--banner=false` above, rather than a second, untested form.
      args += ["--badges=\(request.hasBadges)"]
      args += ["--timestamp=\(request.hasTimestamps)"]
      args += ["--sub-messages=\(request.hasSubMessages)"]
      args += ["--outline=\(request.hasOutline)"]
      // The emote switches are surfaced deliberately: 7TV resolution is why
      // the submodule is pinned past 1.56.5 (CLAUDE.md), not left invisible.
      args += ["--bttv=\(request.isBTTVEnabled)"]
      args += ["--ffz=\(request.isFFZEnabled)"]
      args += ["--stv=\(request.isSTVEnabled)"]
      args += ["--allow-unlisted-emotes=\(request.allowsUnlistedEmotes)"]

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
