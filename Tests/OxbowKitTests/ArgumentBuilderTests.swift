import Foundation
import Testing
@testable import OxbowKit

@Suite("Argument builder")
struct ArgumentBuilderTests {

  private var context: StepContext {
    StepContext(
      stepTempDirectory: URL(filePath: "/tmp/job/step"),
      outputFile: URL(filePath: "/tmp/job/out.mp4"),
      ffmpegPath: URL(filePath: "/Apps/Oxbow.app/Contents/MacOS/ffmpeg"),
      inputArtifacts: [URL(filePath: "/tmp/job/chat.json")])
  }

  private func args(_ kind: StepKind) -> [String] {
    ArgumentBuilder.arguments(for: kind, context: context)
  }

  /// Two inputs, in the order a composite consumes them: the video first, the
  /// chat render second. `ArgumentBuilder` reads them positionally.
  private var compositeContext: StepContext {
    StepContext(
      stepTempDirectory: URL(filePath: "/tmp/job/step"),
      outputFile: URL(filePath: "/tmp/job/composite.mp4"),
      ffmpegPath: URL(filePath: "/Apps/Oxbow.app/Contents/MacOS/ffmpeg"),
      inputArtifacts: [
        URL(filePath: "/tmp/job/video.mp4"),
        URL(filePath: "/tmp/job/render.mp4"),
      ])
  }

  private var composite: StepKind {
    .composite(CompositeRequest(
      framerate: 30, duration: .seconds(60),
      destination: URL(filePath: "/out/x.mp4")))
  }

  private var video: StepKind {
    .downloadVideo(VideoRequest(
      videoID: "2844548319",
      quality: "160p30",
      trimStart: .seconds(0),
      trimEnd: .seconds(40),
      destination: URL(filePath: "/Users/me/Movies/v.mp4")))
  }

  private var clip: StepKind {
    .downloadClip(ClipRequest(
      clipSlug: "AwkwardHelplessSalamanderSwiftRage",
      quality: "480p",
      destination: URL(filePath: "/Users/me/Movies/c.mp4")))
  }

  private var chat: StepKind {
    .downloadChat(ChatRequest(videoID: "1", format: .json))
  }

  private var render: StepKind {
    .renderChat(RenderRequest(bitrateMbps: 3, destination: URL(filePath: "/Users/me/Movies/c.mp4")))
  }

  /// Every verb, in the order `verbs` names them. Parameterised tests index
  /// both, so anything asserted per-verb is asserted for all four.
  private var allKinds: [StepKind] { [video, clip, chat, render] }
  private var verbs: [String] { ["videodownload", "clipdownload", "chatdownload", "chatrender"] }

  /// `--banner` is a per-verb option; before the verb it is a parse error.
  /// Every verb, not just the one — the flag is emitted four separate times.
  @Test(arguments: [0, 1, 2, 3])
  func bannerFlagFollowsTheVerb(index: Int) {
    let a = args(allKinds[index])
    #expect(a.first == verbs[index])
    let banner = try! #require(a.firstIndex(of: "--banner=false"))
    #expect(banner > 0)
  }

  /// The default is Prompt, which would hang the subprocess forever.
  @Test(arguments: [0, 1, 2, 3])
  func collisionIsNeverLeftAtItsPromptingDefault(index: Int) {
    let a = args(allKinds[index])
    let i = try! #require(a.firstIndex(of: "--collision"))
    #expect(a[i + 1] == "Overwrite")
  }

  @Test func videoDownloadPassesIdQualityOutputTempAndFfmpeg() {
    let a = args(video)
    #expect(a.contains("--id"))
    #expect(a.contains("2844548319"))
    #expect(a.contains("160p30"))
    #expect(a.contains("/tmp/job/out.mp4"))
    #expect(a.contains("--temp-path"))
    #expect(a.contains("--ffmpeg-path"))
  }

  @Test func trimTimesAreEmittedInTheCliSecondsFormat() {
    let a = args(video)
    let b = try! #require(a.firstIndex(of: "-b"))
    let e = try! #require(a.firstIndex(of: "-e"))
    #expect(a[b + 1] == "0s")
    #expect(a[e + 1] == "40s")
  }

  @Test func clipDownloadPassesSlugQualityOutputTempAndFfmpeg() {
    let a = args(clip)
    let id = try! #require(a.firstIndex(of: "--id"))
    #expect(a[id + 1] == "AwkwardHelplessSalamanderSwiftRage")
    let quality = try! #require(a.firstIndex(of: "-q"))
    #expect(a[quality + 1] == "480p")
    let output = try! #require(a.firstIndex(of: "-o"))
    #expect(a[output + 1] == "/tmp/job/out.mp4")
    let temp = try! #require(a.firstIndex(of: "--temp-path"))
    #expect(a[temp + 1] == "/tmp/job/step")
    let ffmpeg = try! #require(a.firstIndex(of: "--ffmpeg-path"))
    #expect(a[ffmpeg + 1] == "/Apps/Oxbow.app/Contents/MacOS/ffmpeg")

    // A clip has no trim range: the CLI rejects -b/-e on this verb.
    #expect(!a.contains("-b"))
    #expect(!a.contains("-e"))
  }

  /// `-E` embeds third-party emotes and badges in the chat file. It is opt-in
  /// because it multiplies the file size, so it must appear only when asked.
  @Test func chatDownloadEmbedsImagesOnlyWhenAsked() {
    #expect(!args(chat).contains("-E"))

    let embedding = StepKind.downloadChat(ChatRequest(
      videoID: "1", format: .json, isEmbeddingImages: true))
    #expect(args(embedding).contains("-E"))
  }

  /// The render geometry the user actually chose. `-h` is height, not help.
  @Test func renderPassesGeometryAndFontSize() {
    let a = args(.renderChat(RenderRequest(
      width: 420,
      height: 780,
      framerate: 60,
      fontSize: 14.5,
      destination: URL(filePath: "/tmp/c.mp4"))))

    let width = try! #require(a.firstIndex(of: "-w"))
    #expect(a[width + 1] == "420")
    let height = try! #require(a.firstIndex(of: "-h"))
    #expect(a[height + 1] == "780")
    let framerate = try! #require(a.firstIndex(of: "--framerate"))
    #expect(a[framerate + 1] == "60")
    let fontSize = try! #require(a.firstIndex(of: "--font-size"))
    #expect(a[fontSize + 1] == "14.5")

    let input = try! #require(a.firstIndex(of: "-i"))
    #expect(a[input + 1] == "/tmp/job/chat.json", "the render consumes its dependency's artifact")
  }

  /// chatdownload never invokes FFmpeg, so passing the flag would be an error.
  @Test func chatDownloadDoesNotPassFfmpegPath() {
    #expect(!args(.downloadChat(ChatRequest(videoID: "1", format: .json))).contains("--ffmpeg-path"))
  }

  /// The single most important assertion in the suite: the CLI's default render
  /// encoder is libx264, which is GPL and absent from our LGPL FFmpeg build.
  @Test func renderNeverRequestsLibx264() {
    #expect(!args(render).contains { $0.contains("libx264") })
  }

  @Test func renderRequestsHardwareEncodingViaTheEqualsForm() {
    let outputArgs = try! #require(args(render).first { $0.hasPrefix("--output-args=") })
    #expect(outputArgs.contains("h264_videotoolbox"))
    #expect(outputArgs.contains("-b:v 3M"))
    #expect(outputArgs.contains("{save_path}"))
  }

  /// smartblur is GPL-only and absent from our build; unsharp is the LGPL
  /// replacement. Forwarding --sharpening would fail at runtime.
  @Test func sharpeningUsesUnsharpAndNeverSmartblur() {
    let sharpened = StepKind.renderChat(RenderRequest(
      isSharpened: true, destination: URL(filePath: "/tmp/c.mp4")))
    let a = args(sharpened)

    #expect(!a.contains("--sharpening"))
    #expect(!a.contains { $0.contains("smartblur") })
    #expect(a.contains { $0.hasPrefix("--input-args=") && $0.contains("unsharp") })
  }

  @Test func unsharpenedRenderDoesNotOverrideInputArgs() {
    #expect(!args(render).contains { $0.hasPrefix("--input-args=") })
  }

  @Test func emptyVideoQualityOmitsTheQualityFlag() {
    let kind = StepKind.downloadVideo(VideoRequest(
      videoID: "2844548319",
      quality: "",
      destination: URL(filePath: "/Users/me/Movies/v.mp4")))

    #expect(!args(kind).contains("-q"))
    #expect(!args(kind).contains(""))
  }

  @Test func emptyClipQualityOmitsTheQualityFlag() {
    let kind = StepKind.downloadClip(ClipRequest(
      clipSlug: "SomeClipSlug",
      quality: "",
      destination: URL(filePath: "/Users/me/Movies/c.mp4")))

    #expect(!args(kind).contains("-q"))
    #expect(!args(kind).contains(""))
  }

  @Test func nonEmptyQualityStillPassesTheFlag() {
    #expect(args(video).contains("-q"))
    #expect(args(video).contains("160p30"))
  }

  // MARK: - Appearance options (task 5)

  @Test func renderPassesFont() {
    let a = args(.renderChat(RenderRequest(
      font: "Comic Sans MS", destination: URL(filePath: "/tmp/c.mp4"))))
    let i = try! #require(a.firstIndex(of: "-f"))
    #expect(a[i + 1] == "Comic Sans MS")
  }

  @Test func renderPassesBackgroundColor() {
    let a = args(.renderChat(RenderRequest(
      backgroundColor: "#202020", destination: URL(filePath: "/tmp/c.mp4"))))
    let i = try! #require(a.firstIndex(of: "--background-color"))
    #expect(a[i + 1] == "#202020")
  }

  @Test func renderPassesAlternateBackgroundColor() {
    let a = args(.renderChat(RenderRequest(
      alternateBackgroundColor: "#2a2a2a", destination: URL(filePath: "/tmp/c.mp4"))))
    let i = try! #require(a.firstIndex(of: "--alt-background-color"))
    #expect(a[i + 1] == "#2a2a2a")
  }

  @Test func renderPassesMessageColor() {
    let a = args(.renderChat(RenderRequest(
      messageColor: "#C8FF00", destination: URL(filePath: "/tmp/c.mp4"))))
    let i = try! #require(a.firstIndex(of: "--message-color"))
    #expect(a[i + 1] == "#C8FF00")
  }

  @Test func renderPassesOutlineSize() {
    let a = args(.renderChat(RenderRequest(
      outlineSize: 9, destination: URL(filePath: "/tmp/c.mp4"))))
    let i = try! #require(a.firstIndex(of: "--outline-size"))
    #expect(a[i + 1] == "9")
  }

  /// This whole suite encodes empirically-verified CLI behaviour, not a
  /// guess — do not "tidy" it back to a `--flag=value` shape.
  ///
  /// Upstream declares its boolean render options as switches, not as
  /// `--flag=value` options: the parser reads mere *presence* as true and
  /// ignores any value that follows, so both `--timestamp=false` and
  /// `--timestamp false` turn timestamps ON. Verified against the bundled
  /// 1.56.5 helper on 2026-08-25 by extracting frames from paired
  /// `=false`/`=true` renders and hashing them: `--timestamp=false` and
  /// `--timestamp=true` produced byte-identical frames (sha256
  /// `d9b7fea7be2a10be…`), differing only from omitting the flag entirely
  /// (`6a2b525002429b03…`); same result for `--outline` (`735d58632d7ada2c…`
  /// identical, `53952cd96edf2289…` when omitted). There is no way to pass
  /// `false` through this CLI. `--banner` is a genuine exception — it is
  /// declared differently upstream and its `=false` form really does
  /// suppress the banner — which is why it is untouched everywhere else in
  /// this file.
  ///
  /// Of `RenderRequest`'s render-option booleans, only three default to
  /// `false` and are therefore fully expressible: absent means false, the
  /// bare flag (no `=value`) means true. The other six the CLI defaults to
  /// `true` (`--badges`, `--sub-messages`, `--bttv`, `--ffz`, `--stv`,
  /// `--allow-unlisted-emotes`) cannot be turned off through this CLI at
  /// all, so `RenderRequest` has no fields for them — see
  /// `renderNeverEmitsTheSixUnexpressibleTrueDefaultSwitches` below.
  /// Always on, and not a `RenderRequest` field, because there is no good
  /// reason to want the alternative.
  ///
  /// A Twitch API change in November 2022 made downloaded chat carry only
  /// whole-second timestamps, so six messages sent across one second all
  /// record as the same instant and the render drops all six on screen at
  /// once, then shows nothing until the next second. `--dispersion` uses the
  /// additional metadata to restore when messages were actually sent.
  ///
  /// The CLI documents it as requiring an update rate below 1.0 to be
  /// effective. We never pass `--update-rate`, and upstream's default is 0.2,
  /// so the precondition holds and the bare flag alone is enough — asserted
  /// below so that passing `--update-rate` later cannot silently neuter this.
  ///
  /// The pinned submodule contains upstream's rewritten algorithm
  /// (`861b493`, "New, more accurate dispersion algorithm", #1636), not the
  /// 2019 original.
  @Test func renderAlwaysDispersesWholeSecondTimestamps() {
    let a = args(.renderChat(RenderRequest(destination: URL(filePath: "/tmp/c.mp4"))))
    #expect(a.contains("--dispersion"))
    #expect(!a.contains { $0.hasPrefix("--dispersion=") })
    // The precondition: an update rate below 1.0. We rely on the CLI default
    // of 0.2 by never setting it.
    #expect(!a.contains("--update-rate"))
    #expect(!a.contains { $0.hasPrefix("--update-rate=") })
  }

  @Test func alternateBackgroundsFlagIsBareAndOnlyPresentWhenTrue() {
    let off = args(.renderChat(RenderRequest(destination: URL(filePath: "/tmp/c.mp4"))))
    #expect(!off.contains("--alternate-backgrounds"))
    #expect(!off.contains { $0.hasPrefix("--alternate-backgrounds=") })

    let on = args(.renderChat(RenderRequest(
      hasAlternateBackgrounds: true, destination: URL(filePath: "/tmp/c.mp4"))))
    #expect(on.contains("--alternate-backgrounds"))
  }

  @Test func timestampFlagIsBareAndOnlyPresentWhenTrue() {
    let off = args(.renderChat(RenderRequest(destination: URL(filePath: "/tmp/c.mp4"))))
    #expect(!off.contains("--timestamp"))
    #expect(!off.contains { $0.hasPrefix("--timestamp=") })

    let on = args(.renderChat(RenderRequest(
      hasTimestamps: true, destination: URL(filePath: "/tmp/c.mp4"))))
    #expect(on.contains("--timestamp"))
  }

  @Test func outlineFlagIsBareAndOnlyPresentWhenTrue() {
    let off = args(.renderChat(RenderRequest(destination: URL(filePath: "/tmp/c.mp4"))))
    #expect(!off.contains("--outline"))
    #expect(!off.contains { $0.hasPrefix("--outline=") })

    let on = args(.renderChat(RenderRequest(
      hasOutline: true, destination: URL(filePath: "/tmp/c.mp4"))))
    #expect(on.contains("--outline"))
  }

  /// The six switches the CLI defaults to `true` cannot be turned off at
  /// all (see the suite comment above), so they must never appear in argv in
  /// any form — bare, `=true`, or `=false` — regardless of what the request
  /// asks for. The emote switches were surfaced deliberately in an earlier
  /// design (7TV resolution is why the submodule is pinned past 1.56.5,
  /// CLAUDE.md); they remain on by the CLI's own default, just no longer as
  /// settable — and therefore no longer visible — fields.
  @Test func renderNeverEmitsTheSixUnexpressibleTrueDefaultSwitches() {
    let a = args(render)
    let unexpressible = ["--badges", "--sub-messages", "--bttv", "--ffz", "--stv", "--allow-unlisted-emotes"]
    for flag in unexpressible {
      #expect(!a.contains { $0 == flag || $0.hasPrefix("\(flag)=") }, "\(flag) must never be emitted")
    }
  }

  /// Isolates exactly one field away from its default (all three share the
  /// `false` default), so a builder that swapped which field fed which flag
  /// — `hasAlternateBackgrounds`↔`hasTimestamps`, `hasTimestamps`↔
  /// `hasOutline`, or `hasOutline`↔`hasAlternateBackgrounds` — surfaces as
  /// the wrong token in `onlyInFlipped`, not a passing test: starting from an
  /// all-defaults request, flipping exactly one boolean field must add
  /// **exactly one** token, and it must be the bare flag this field owns,
  /// with nothing removed. Table-driven so a future false-defaulting boolean
  /// field is one row, not a new test.
  private struct BooleanFieldCase {
    let field: String
    let flagToken: String
    let flip: (inout RenderRequest) -> Void
  }

  // `isSharpened` is the fourth `Bool` on `RenderRequest` and is deliberately
  // NOT a row here: it does not emit a bare `--flag` like the other three.
  // It conditionally appends an entire `--input-args=...` string (the
  // unsharp filter), a shape this table's add-one-bare-flag check can't
  // express, and it defaults to `false` for an unrelated reason (GPL
  // avoidance, not an upstream parsing quirk). It already has its own
  // dedicated coverage — `sharpeningUsesUnsharpAndNeverSmartblur` and
  // `unsharpenedRenderDoesNotOverrideInputArgs`, above.
  // `boolFieldCountMatchesTableRowsPlusDocumentedExclusions` enforces that
  // this is the *only* exclusion: a future `Bool` field added without
  // either a row here or a documented exclusion like this one fails that
  // guard instead of silently widening the blind spot.
  private var booleanFieldCases: [BooleanFieldCase] {
    [
      BooleanFieldCase(field: "hasAlternateBackgrounds", flagToken: "--alternate-backgrounds") {
        $0.hasAlternateBackgrounds = true
      },
      BooleanFieldCase(field: "hasTimestamps", flagToken: "--timestamp") {
        $0.hasTimestamps = true
      },
      BooleanFieldCase(field: "hasOutline", flagToken: "--outline") {
        $0.hasOutline = true
      },
    ]
  }

  @Test func flippingExactlyOneBooleanFieldAddsExactlyThatFieldsOwnBareFlagAndNoOther() {
    let baseline = args(.renderChat(RenderRequest(destination: URL(filePath: "/tmp/c.mp4"))))

    for testCase in booleanFieldCases {
      var request = RenderRequest(destination: URL(filePath: "/tmp/c.mp4"))
      testCase.flip(&request)
      let flipped = args(.renderChat(request))

      let onlyInBaseline = Set(baseline).subtracting(flipped)
      let onlyInFlipped = Set(flipped).subtracting(baseline)

      #expect(
        onlyInBaseline.isEmpty,
        "flipping \(testCase.field) unexpectedly removed \(onlyInBaseline)")
      #expect(
        onlyInFlipped == [testCase.flagToken],
        "flipping \(testCase.field) added \(onlyInFlipped), expected only [\(testCase.flagToken)]")
    }
  }

  /// Makes the table self-enforcing: without this, a `Bool` field added to
  /// `RenderRequest` in the future with neither a row above nor a documented
  /// exclusion (like `isSharpened`'s, commented above `booleanFieldCases`)
  /// would silently widen the swap blind spot the table exists to close, and
  /// nothing would say so. `Mirror` over a default-constructed request
  /// counts every `Bool` stored property — the three rows plus the one
  /// documented, named exclusion must account for all of them, or this fails
  /// and says exactly what changed.
  @Test func boolFieldCountMatchesTableRowsPlusDocumentedExclusions() {
    let documentedExclusions = 1 // isSharpened — see the comment above `booleanFieldCases`.
    let mirror = Mirror(reflecting: RenderRequest(destination: URL(filePath: "/tmp/c.mp4")))
    let boolFieldCount = mirror.children.filter { $0.value is Bool }.count

    let message = "RenderRequest has \(boolFieldCount) Bool fields but the table only accounts for "
      + "\(booleanFieldCases.count) rows + \(documentedExclusions) documented exclusion(s); "
      + "a Bool field was added without a row or a documented, counted exclusion"
    #expect(boolFieldCount == booleanFieldCases.count + documentedExclusions, "\(message)")
  }

  /// The two GPL-avoidance rules must keep holding once appearance options are
  /// interleaved into the same argv: a wrong implementation that emits the new
  /// flags but regresses --output-args or lets --sharpening slip back in would
  /// still pass every single-field test above.
  @Test func gplRulesStillHoldAlongsideTheNewAppearanceOptions() {
    let a = args(.renderChat(RenderRequest(
      font: "Comic Sans MS",
      backgroundColor: "#000000",
      alternateBackgroundColor: "#101010",
      hasAlternateBackgrounds: true,
      messageColor: "#eeeeee",
      hasTimestamps: true,
      hasOutline: true,
      outlineSize: 2,
      isSharpened: true,
      destination: URL(filePath: "/tmp/c.mp4"))))

    let outputArgs = try! #require(a.first { $0.hasPrefix("--output-args=") })
    #expect(outputArgs.contains("h264_videotoolbox"))
    #expect(!a.contains { $0.contains("libx264") })
    #expect(!a.contains("--sharpening"))
    #expect(!a.contains { $0.contains("smartblur") })
    #expect(a.contains { $0.hasPrefix("--input-args=") && $0.contains("unsharp") })
  }

  @Test func compositeStacksTheChatColumnBesideTheVideo() {
    let request = CompositeRequest(
      framerate: 60,
      duration: .seconds(3600),
      destination: URL(filePath: "/out/stream.mp4"))

    let args = ArgumentBuilder.arguments(for: .composite(request), context: compositeContext)

    #expect(args == [
      "-nostdin", "-y", "-hide_banner",
      "-i", "/tmp/job/video.mp4",
      "-i", "/tmp/job/render.mp4",
      "-map", "0:a:0?",
      "-c:a", "copy",
      "/tmp/job/audio.m4a",
      "-filter_complex",
      "[0:v]fps=60:start_time=0[v];"
        + "[1:v]setpts=PTS-STARTPTS,fps=60[c];"
        + "[v][c]hstack=inputs=2[out]",
      "-map", "[out]",
      "-an",
      "-c:v", "h264_videotoolbox",
      "-q:v", "50",
      "-pix_fmt", "yuv420p",
      "-progress", "pipe:1",
      "-nostats",
      "-loglevel", "error",
      "-movflags", "+frag_keyframe+empty_moov+default_base_moof",
      "/tmp/job/composite.mp4",
    ])
  }

  /// The video branch must not zero its own start timestamp.
  ///
  /// A trimmed download legitimately begins its video stream *after* its
  /// audio: upstream trims with an input `-ss` and `-c copy`, and a stream
  /// copy can only start video on a keyframe, so the file honestly records
  /// `video start_time = 0.866, audio start_time = 0.000` and every player
  /// honours the gap.
  ///
  /// `setpts=PTS-STARTPTS` on `[0:v]` threw that gap away. The audio never
  /// passes through the filter graph — it is `-c:a copy`-ed to the sidecar
  /// and remuxed untouched at `.assemble` — so the two halves of one source
  /// were rebased by different amounts and the delivery came out with its
  /// video 0.866s early. Measured on a real 20-minute trimmed VOD: a
  /// 24-frame lag, constant at both ends of the file, reproduced exactly by
  /// replaying this argv against a clean download.
  ///
  /// `fps=…:start_time=0` holds the first frame across the gap instead of
  /// dragging the whole track earlier, so output time *is* source time —
  /// which is what `docs/design/resume.md` §2 already claimed and this made
  /// true. Do not "simplify" it back to `setpts`.
  ///
  /// It is deliberately not a bare removal either: dropping the reset
  /// outright made `h264_videotoolbox` abort mid-encode on a source starting
  /// at 0.666s (`composite-quality.md` §9). The output stays zero-based and
  /// CFR; only the padding changes.
  @Test func compositeKeepsTheVideoOnItsSourceTimeline() {
    let a = ArgumentBuilder.arguments(
      for: .composite(CompositeRequest(
        framerate: 30, duration: .seconds(60),
        destination: URL(filePath: "/out/x.mp4"))),
      context: compositeContext)

    let graph = a[try! #require(a.firstIndex(of: "-filter_complex")) + 1]

    #expect(graph.hasPrefix("[0:v]fps=30:start_time=0[v];"))
    #expect(!graph.contains("[0:v]setpts"))
    // The chat render always starts at zero and still needs zero-basing
    // before the rate conversion.
    #expect(graph.contains("[1:v]setpts=PTS-STARTPTS,fps=30[c];"))
  }

  /// A quality target, never a bitrate, and never `-maxrate`.
  ///
  /// `docs/design/composite-rate-control.md` §2: one `q:v 50` holds the chat
  /// column within 1.9 dB across content whose bitrate requirement spans 5.3x,
  /// and beats a fixed target by +6.3 dB *at the same bitrate*, because a fixed
  /// target spreads bits evenly through time and the chat column's difficulty
  /// is not evenly distributed.
  ///
  /// **`-maxrate` is forbidden, and it is not obvious why** (§7.1). It looks
  /// like the guard against a runaway bitrate and does the opposite: adding
  /// `-maxrate 30M` took ordinary content from 5.0 to 19.3 Mbps. Neither
  /// `-q:v` nor `-maxrate` is an encoder option — `-q:v` reaches
  /// `kVTCompressionPropertyKey_Quality` through ffmpeg's generic
  /// `global_quality` path, while `-maxrate` maps to `DataRateLimits`, a
  /// different rate-control mode. Setting it switches the encoder out of
  /// quality mode rather than bounding it.
  @Test func compositeTargetsQualityRatherThanABitrate() {
    let a = ArgumentBuilder.arguments(
      for: .composite(CompositeRequest(
        framerate: 60, duration: .seconds(3600),
        destination: URL(filePath: "/out/x.mp4"))),
      context: compositeContext)

    let q = try! #require(a.firstIndex(of: "-q:v"))
    #expect(a[q + 1] == "50")
    #expect(!a.contains("-b:v"))
    #expect(!a.contains("-maxrate"))
    #expect(!a.contains("-bufsize"))
    #expect(!a.contains("-constant_bit_rate"))
  }

  /// The chat render's own bitrate is a different decision and stays.
  ///
  /// It is an intermediate that the composite immediately re-encodes, and
  /// `composite-quality.md` §2.2 measured its contribution to the final error
  /// at ~5%. Switching it to a quality target would buy nothing and cost a
  /// second constant to reason about.
  @Test func theChatRenderKeepsItsOwnBitrate() {
    let a = args(.renderChat(RenderRequest(
      bitrateMbps: 12, destination: URL(filePath: "/tmp/c.mp4"))))
    #expect(a.contains { $0.hasPrefix("--output-args=") && $0.contains("-b:v 12M") })
    #expect(!a.contains { $0.hasPrefix("--output-args=") && $0.contains("-q:v") })
  }

  /// The prototype this replaces carried `shortest=1`, which truncates the
  /// video to the chat's length whenever a stream goes quiet before it ends.
  @Test func compositeNeverPassesShortestOrFaststartOrAGPLEncoder() {
    let request = CompositeRequest(
      framerate: 30, duration: .seconds(60),
      destination: URL(filePath: "/out/x.mp4"))
    let context = StepContext(
      stepTempDirectory: URL(filePath: "/tmp/s"),
      outputFile: URL(filePath: "/tmp/s/composite.mp4"),
      ffmpegPath: URL(filePath: "/bin/ffmpeg"),
      inputArtifacts: [URL(filePath: "/w/v.mp4"), URL(filePath: "/w/r.mp4")])
    let joined = ArgumentBuilder.arguments(for: .composite(request), context: context)
      .joined(separator: " ")

    #expect(!joined.contains("shortest"))
    #expect(!joined.contains("faststart"))
    #expect(!joined.contains("libx264"))
    #expect(joined.contains("h264_videotoolbox"))
  }

  @Test func compositeIsAComputeStep() {
    let request = CompositeRequest(
      framerate: 30, duration: .seconds(60),
      destination: URL(filePath: "/out/x.mp4"))
    #expect(StepKind.composite(request).resource == .compute)
  }

  /// Seeking by time, never by frame index. On Twitch sources those two
  /// disagree — docs/design/resume.md §2.1 has the measurements.
  ///
  /// Both inputs are seeked: the video and the chat render must start at the
  /// same moment or the stack is offset.
  @Test func aResumingCompositeSeeksBothInputs() {
    var context = compositeContext
    context.resumeFrom = .seconds(74.4)
    let args = ArgumentBuilder.arguments(for: composite, context: context)

    let seeks = args.indices.filter { args[$0] == "-ss" }
    #expect(seeks.count == 2)
    for index in seeks { #expect(args[index + 1] == "74.400000") }
    // -ss must precede the -i it applies to, or it seeks the wrong thing.
    for index in seeks { #expect(args[index + 2] == "-i") }
  }

  @Test func aFirstAttemptDoesNotSeek() {
    #expect(!ArgumentBuilder.arguments(for: composite, context: compositeContext).contains("-ss"))
  }

  /// The fragmentation flags from fragmented-output.md §3 are what make resume
  /// possible at all; they must survive on both paths.
  /// The first attempt copies the source's audio out beside piece 0, in the
  /// same invocation — it is a stream copy, so it costs nothing, and it is what
  /// lets §5 delete the 16.3 GB source before assembling. `compositeContext`
  /// carries no sidecar yet (`hasUsableSidecar` defaults to `false`), which is
  /// exactly a first attempt's situation. resume.md §4.
  @Test func aFirstAttemptAlsoWritesTheSidecarAudio() {
    let args = ArgumentBuilder.arguments(for: composite, context: compositeContext)

    #expect(args.contains { $0.hasSuffix("audio.m4a") })
    #expect(args.contains("0:a:0?"))
    // A first attempt is already un-seeked at input 0 — no third input needed.
    #expect(args.filter { $0 == "-i" }.count == 2)
  }

  /// Once a usable sidecar exists, resuming must not touch it: a resumed
  /// attempt holds only the tail, so re-extracting would truncate the sidecar
  /// to it. The gate is usability, not attempt number — this is the case where
  /// the first attempt's own copy is intact and complete.
  @Test func aResumingCompositeWithAUsableSidecarDoesNotRewriteIt() {
    var context = compositeContext
    context.resumeFrom = .seconds(10)
    context.hasUsableSidecar = true
    let args = ArgumentBuilder.arguments(for: composite, context: context)

    #expect(!args.contains { $0.hasSuffix("audio.m4a") })
    // No reason to add a third input when nothing needs its audio.
    #expect(args.filter { $0 == "-i" }.count == 2)
  }

  /// The defect this branch exists to fix: a `SIGKILL` during the sidecar's
  /// own write (an ordinary, non-fragmented MP4) leaves it with no `moov`,
  /// permanently, unless a later attempt gets a chance to rewrite it. Gating
  /// on `resumeFrom == nil` alone meant no later attempt ever did — every
  /// retry re-encoded the tail successfully and then failed at `.assemble` on
  /// the same corrupt file, until the piece cap forced a full restart.
  /// resume.md §4.
  ///
  /// Rewriting on a resume needs an un-seeked copy of the source: both
  /// existing inputs carry `-ss`, so mapping from input 0 would capture only
  /// the tail, silently truncating the sidecar instead of restoring it. A
  /// third, un-seeked input supplies the whole track.
  @Test func aResumingCompositeWithAnUnusableSidecarRewritesItFromAThirdInput() {
    var context = compositeContext
    context.resumeFrom = .seconds(10)
    context.hasUsableSidecar = false
    let args = ArgumentBuilder.arguments(for: composite, context: context)

    #expect(args.contains { $0.hasSuffix("audio.m4a") })
    #expect(args.contains("2:a:0?"))
    #expect(!args.contains("0:a:0?"))

    // Three inputs: video (seeked), chat (seeked), video again (un-seeked).
    let inputIndices = args.indices.filter { args[$0] == "-i" }
    #expect(inputIndices.count == 3)
    #expect(args[inputIndices[0] + 1] == "/tmp/job/video.mp4")
    #expect(args[inputIndices[1] + 1] == "/tmp/job/render.mp4")
    #expect(args[inputIndices[2] + 1] == "/tmp/job/video.mp4")

    // Exactly two `-ss`, both for the composited pair — the third input gets
    // none, so it is not identically-seeked with the other two, it is simply
    // un-seeked. Same style as `aResumingCompositeSeeksBothInputs`: each
    // `-ss` is immediately followed by its value, then its `-i`.
    let seeks = args.indices.filter { args[$0] == "-ss" }
    #expect(seeks.count == 2)
    for index in seeks {
      #expect(args[index + 1] == "10.000000")
      #expect(args[index + 2] == "-i")
    }
    // Neither seeked `-i` is the third one — it is preceded by the chat
    // input's path, not by a `-ss`/value pair.
    #expect(!seeks.contains(inputIndices[2] - 2))
  }

  @Test func aResumingCompositeKeepsTheFragmentFlags() {
    var context = compositeContext
    context.resumeFrom = .seconds(10)
    let args = ArgumentBuilder.arguments(for: composite, context: context)

    #expect(args.contains("+frag_keyframe+empty_moov+default_base_moof"))
    #expect(!args.contains("+faststart"))
  }

  /// One piece is the ordinary case — every job that never failed. Concat of a
  /// single input still produces a correct file and keeps one code path.
  @Test func assembleWithOnePieceConcatenatesIt() {
    let context = StepContext(
      stepTempDirectory: URL(filePath: "/tmp/job/step"),
      outputFile: URL(filePath: "/tmp/job/final.mp4"),
      ffmpegPath: URL(filePath: "/Apps/Oxbow.app/Contents/MacOS/ffmpeg"),
      inputArtifacts: [URL(filePath: "/tmp/resume/audio.m4a")])
    let args = ArgumentBuilder.arguments(
      for: .assemble(AssembleRequest(destination: URL(filePath: "/Users/me/out.mp4"))),
      context: context)

    #expect(args.contains("-nostdin"))
    #expect(args.contains("concat"))
    #expect(args.contains("-c"))
    #expect(args.contains("copy"))
    // Audio comes from the sidecar copied out on the first attempt, never
    // from a piece (pieces are video-only) and never from the downloaded video
    // (deleted before assemble). See docs/design/resume.md §4 and §6.
    #expect(args.contains("1:a:0?"))
    #expect(args.contains("/tmp/resume/audio.m4a"))
    #expect(args.last == "/tmp/job/final.mp4")
    #expect(!args.contains("+faststart"))
  }

  @Test func assembleIsAComputeStep() {
    let kind = StepKind.assemble(AssembleRequest(destination: URL(filePath: "/x.mp4")))
    #expect(kind.resource == .compute)
  }
}
