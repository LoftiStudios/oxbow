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
      inputArtifact: URL(filePath: "/tmp/job/chat.json"))
  }

  private func args(_ kind: StepKind) -> [String] {
    ArgumentBuilder.arguments(for: kind, context: context)
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

  /// One render request per boolean field, with every other boolean field
  /// deliberately flipped to its non-default value. If the builder ever wired
  /// a flag to the wrong field, this would produce two flags disagreeing with
  /// their expected value instead of one silently matching by coincidence.
  private func renderRequestWithAllBooleansFlipped() -> RenderRequest {
    RenderRequest(
      hasBadges: false,
      hasTimestamps: true,
      hasSubMessages: false,
      hasOutline: true,
      isBTTVEnabled: false,
      isFFZEnabled: false,
      isSTVEnabled: false,
      allowsUnlistedEmotes: false,
      destination: URL(filePath: "/tmp/c.mp4"))
  }

  /// The CLI's boolean options are single-token `--flag=true|false`, the same
  /// shape as the already-proven `--banner=false`. Two separate tokens would
  /// also parse, but mixing forms invites the space-separated mistake the
  /// `--opt=value` rule exists to avoid, so every boolean option here follows
  /// the one shape throughout. Each flag is checked against its flipped
  /// (non-default) value, so a builder that just echoed the default back
  /// would not pass.
  @Test func badgesFlagMatchesTheFlippedValue() {
    #expect(args(.renderChat(renderRequestWithAllBooleansFlipped())).contains("--badges=false"))
  }

  @Test func timestampFlagMatchesTheFlippedValue() {
    #expect(args(.renderChat(renderRequestWithAllBooleansFlipped())).contains("--timestamp=true"))
  }

  @Test func subMessagesFlagMatchesTheFlippedValue() {
    #expect(args(.renderChat(renderRequestWithAllBooleansFlipped())).contains("--sub-messages=false"))
  }

  @Test func outlineFlagMatchesTheFlippedValue() {
    #expect(args(.renderChat(renderRequestWithAllBooleansFlipped())).contains("--outline=true"))
  }

  @Test func bttvFlagMatchesTheFlippedValue() {
    #expect(args(.renderChat(renderRequestWithAllBooleansFlipped())).contains("--bttv=false"))
  }

  @Test func ffzFlagMatchesTheFlippedValue() {
    #expect(args(.renderChat(renderRequestWithAllBooleansFlipped())).contains("--ffz=false"))
  }

  @Test func stvFlagMatchesTheFlippedValue() {
    #expect(args(.renderChat(renderRequestWithAllBooleansFlipped())).contains("--stv=false"))
  }

  @Test func allowUnlistedEmotesFlagMatchesTheFlippedValue() {
    let a = args(.renderChat(renderRequestWithAllBooleansFlipped()))
    #expect(a.contains("--allow-unlisted-emotes=false"))
  }

  /// 7TV resolution is why the submodule is pinned past 1.56.5 (CLAUDE.md); the
  /// switch defaulting on and staying visible in argv is the point of surfacing
  /// it at all, not just a side effect of a generic default table.
  @Test func stvEmotesDefaultOnAndAreVisibleInArgv() {
    #expect(args(render).contains("--stv=true"))
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
      messageColor: "#eeeeee",
      hasBadges: false,
      hasTimestamps: true,
      hasSubMessages: false,
      hasOutline: true,
      outlineSize: 2,
      isBTTVEnabled: false,
      isFFZEnabled: false,
      isSTVEnabled: false,
      allowsUnlistedEmotes: false,
      isSharpened: true,
      destination: URL(filePath: "/tmp/c.mp4"))))

    let outputArgs = try! #require(a.first { $0.hasPrefix("--output-args=") })
    #expect(outputArgs.contains("h264_videotoolbox"))
    #expect(!a.contains { $0.contains("libx264") })
    #expect(!a.contains("--sharpening"))
    #expect(!a.contains { $0.contains("smartblur") })
    #expect(a.contains { $0.hasPrefix("--input-args=") && $0.contains("unsharp") })
  }
}
