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

  /// Render booleans are presence-only switches: even `--timestamp=false` enables timestamps.
  /// Paired renders verified this on helper 1.56.5; `--banner=false` is a separately declared
  /// exception. False-default options use absence for false and a bare flag for true.
  /// True-default emote/badge options cannot be disabled. Dispersion stays enabled to restore
  /// subsecond chat timing and requires update rate below 1.0 (upstream default 0.2); pin that
  /// no override defeats it.
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

  /// True-default render switches cannot be disabled; leave them absent and rely on CLI
  /// defaults.
  @Test func renderNeverEmitsTheSixUnexpressibleTrueDefaultSwitches() {
    let a = args(render)
    let unexpressible = ["--badges", "--sub-messages", "--bttv", "--ffz", "--stv", "--allow-unlisted-emotes"]
    for flag in unexpressible {
      #expect(!a.contains { $0 == flag || $0.hasPrefix("\(flag)=") }, "\(flag) must never be emitted")
    }
  }

  /// Flip one boolean at a time and require exactly its bare flag to be added, catching swapped
  /// field mappings.
  private struct BooleanFieldCase {
    let field: String
    let flagToken: String
    let flip: (inout RenderRequest) -> Void
  }

  // Exclude `isSharpened`: it changes the input-args filter rather than emitting a bare switch
  // and has dedicated coverage. The reflected count below guards against undocumented
  // exclusions.
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

  /// Count stored Bool fields so every future option needs a table row or explicit exclusion.
  @Test func boolFieldCountMatchesTableRowsPlusDocumentedExclusions() {
    let documentedExclusions = 1 // isSharpened — see the comment above `booleanFieldCases`.
    let mirror = Mirror(reflecting: RenderRequest(destination: URL(filePath: "/tmp/c.mp4")))
    let boolFieldCount = mirror.children.filter { $0.value is Bool }.count

    let message = "RenderRequest has \(boolFieldCount) Bool fields but the table only accounts for "
      + "\(booleanFieldCases.count) rows + \(documentedExclusions) documented exclusion(s); "
      + "a Bool field was added without a row or a documented, counted exclusion"
    #expect(boolFieldCount == booleanFieldCases.count + documentedExclusions, "\(message)")
  }

  /// Combined appearance options must still preserve LGPL output args and avoid `--sharpening`.
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

  /// Preserve a trimmed source's video/audio start gap. `setpts=PTS-STARTPTS` removes the video
  /// offset while copied audio retains it, causing drift. `fps=…:start_time=0` pads the gap
  /// with the first frame; removing rebasing outright can make VideoToolbox abort. See
  /// `composite-quality.md` §9.
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

  /// Pin quality mode without bitrate or maxrate. `-maxrate` selects VideoToolbox
  /// DataRateLimits instead of bounding quality mode, and measured output grew from 5.0 to 19.3
  /// Mbps. See `composite-rate-control.md` §7.1.
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

  /// Keep the intermediate chat-render bitrate; its quality contribution was measured
  /// separately in `composite-quality.md` §2.2.
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

  /// Seek both inputs by time; source frame count and wall time can diverge (`resume.md` §2.1).
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

  /// Chat may end before video. Seeking beyond it leaves no frame for `hstack` to repeat and
  /// can emit an empty piece with exit 0. Context construction clamps chat seek inside its
  /// duration; argument building uses that separate value.
  @Test func aResumeBeyondTheChatRenderClampsOnlyTheChatSeek() {
    var context = compositeContext
    context.resumeFrom = .seconds(74.4)
    context.chatResumeFrom = .seconds(4.966667)
    let args = ArgumentBuilder.arguments(for: composite, context: context)

    let seeks = args.indices.filter { args[$0] == "-ss" }
    #expect(seeks.count == 2)
    // [-ss][value][-i][path]
    #expect(args[seeks[0] + 1] == "74.400000")
    #expect(args[seeks[0] + 3] == "/tmp/job/video.mp4")
    #expect(args[seeks[1] + 1] == "4.966667")
    #expect(args[seeks[1] + 3] == "/tmp/job/render.mp4")
  }

  /// Absent chat override keeps both seeks at the same instant.
  @Test func aChatRenderLongEnoughToSeekIsSeekedWithTheVideo() {
    var context = compositeContext
    context.resumeFrom = .seconds(74.4)
    let args = ArgumentBuilder.arguments(for: composite, context: context)

    let seeks = args.indices.filter { args[$0] == "-ss" }
    #expect(seeks.count == 2)
    for index in seeks { #expect(args[index + 1] == "74.400000") }
  }

  @Test func aFirstAttemptDoesNotSeek() {
    #expect(!ArgumentBuilder.arguments(for: composite, context: compositeContext).contains("-ss"))
  }

  /// Pin fragmentation on initial and resumed pieces. Initial attempts also copy audio into
  /// retention so assembly can run after source removal.
  @Test func aFirstAttemptAlsoWritesTheSidecarAudio() {
    let args = ArgumentBuilder.arguments(for: composite, context: compositeContext)

    #expect(args.contains { $0.hasSuffix("audio.m4a") })
    #expect(args.contains("0:a:0?"))
    // A first attempt is already un-seeked at input 0 — no third input needed.
    #expect(args.filter { $0 == "-i" }.count == 2)
  }

  /// An intact sidecar must remain untouched on resume.
  @Test func aResumingCompositeWithAUsableSidecarDoesNotRewriteIt() {
    var context = compositeContext
    context.resumeFrom = .seconds(10)
    context.hasUsableSidecar = true
    let args = ArgumentBuilder.arguments(for: composite, context: context)

    #expect(!args.contains { $0.hasSuffix("audio.m4a") })
    // No reason to add a third input when nothing needs its audio.
    #expect(args.filter { $0 == "-i" }.count == 2)
  }

  /// A killed sidecar lacks `moov` and must be rewritten on retry. Use a third, unseeked source
  /// input so replacement audio spans the whole video, not just the resumed tail.
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

    // Only the two composite inputs receive `-ss`; the sidecar source remains unseeked.
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
    // Assembly audio comes from retention, not video-only pieces or the deleted source.
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
