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

  /// `--alt-background-color` is documented by the CLI as inert without this
  /// separate toggle also on. Isolated flip (everything else default) so a
  /// swap with a neighbouring same-default boolean would be caught too.
  @Test func renderPassesAlternateBackgroundsToggle() {
    let a = args(.renderChat(RenderRequest(
      hasAlternateBackgrounds: true, destination: URL(filePath: "/tmp/c.mp4"))))
    #expect(a.contains("--alternate-backgrounds=true"))
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

  /// Each boolean test isolates exactly one field away from its default,
  /// leaving every other field — including the rest of its own family
  /// (`hasBadges`/`hasSubMessages`, and the four emote switches, all of which
  /// share a `true` default) — untouched at `RenderRequest()`'s default.
  ///
  /// This is deliberate, not just tidier than one shared "everything flipped"
  /// fixture. A prior version of this suite flipped every boolean field to
  /// its opposite in one shared request; within a same-default family that
  /// drives every member to the *same* flipped value (all four emote fields
  /// became `false` together), so a builder that swapped which field fed
  /// which flag — `--bttv`↔`--ffz`, `--ffz`↔`--stv`, `--stv`↔
  /// `--allow-unlisted-emotes`, or `--badges`↔`--sub-messages` — would emit
  /// an identical set of `flag=value` strings and every test would still
  /// pass. Isolating the field under test means a same-default sibling swap
  /// now surfaces as `flag=<the sibling's untouched default>`, which
  /// disagrees with the flipped value this test asserts — caught instead of
  /// silently matching. Confirmed empirically below (see the swap
  /// demonstration in the report), not just reasoned about.
  ///
  /// The CLI's boolean options are single-token `--flag=true|false`, the same
  /// shape as the already-proven `--banner=false`; checking the fused string
  /// (rather than checking the flag and the value as two separate
  /// `#expect`s) is what makes "flag and value adjacent" actually load-
  /// bearing here — there is no way for `contains` to match a flag whose
  /// value came from a different field.
  @Test func badgesFlagMatchesItsOwnFlippedValueNotASiblings() {
    let a = args(.renderChat(RenderRequest(hasBadges: false, destination: URL(filePath: "/tmp/c.mp4"))))
    #expect(a.contains("--badges=false"))
  }

  @Test func timestampFlagMatchesItsOwnFlippedValueNotASiblings() {
    let a = args(.renderChat(RenderRequest(hasTimestamps: true, destination: URL(filePath: "/tmp/c.mp4"))))
    #expect(a.contains("--timestamp=true"))
  }

  @Test func subMessagesFlagMatchesItsOwnFlippedValueNotASiblings() {
    let a = args(.renderChat(RenderRequest(hasSubMessages: false, destination: URL(filePath: "/tmp/c.mp4"))))
    #expect(a.contains("--sub-messages=false"))
  }

  @Test func outlineFlagMatchesItsOwnFlippedValueNotASiblings() {
    let a = args(.renderChat(RenderRequest(hasOutline: true, destination: URL(filePath: "/tmp/c.mp4"))))
    #expect(a.contains("--outline=true"))
  }

  @Test func bttvFlagMatchesItsOwnFlippedValueNotASiblings() {
    let a = args(.renderChat(RenderRequest(isBTTVEnabled: false, destination: URL(filePath: "/tmp/c.mp4"))))
    #expect(a.contains("--bttv=false"))
  }

  @Test func ffzFlagMatchesItsOwnFlippedValueNotASiblings() {
    let a = args(.renderChat(RenderRequest(isFFZEnabled: false, destination: URL(filePath: "/tmp/c.mp4"))))
    #expect(a.contains("--ffz=false"))
  }

  @Test func stvFlagMatchesItsOwnFlippedValueNotASiblings() {
    let a = args(.renderChat(RenderRequest(isSTVEnabled: false, destination: URL(filePath: "/tmp/c.mp4"))))
    #expect(a.contains("--stv=false"))
  }

  @Test func allowUnlistedEmotesFlagMatchesItsOwnFlippedValueNotASiblings() {
    let a = args(.renderChat(RenderRequest(
      allowsUnlistedEmotes: false, destination: URL(filePath: "/tmp/c.mp4"))))
    #expect(a.contains("--allow-unlisted-emotes=false"))
  }

  /// The per-field tests above isolate one field per request, which catches a
  /// swap between two fields that share a default (both `true`, or both
  /// `false`) — see the comment above them. It does **not** catch a swap
  /// between two fields with *opposite* defaults: e.g. swap `--badges`
  /// (default `true`) with `--timestamp` (default `false`) and, in the
  /// isolated `hasBadges` test, the untouched `hasTimestamps` sits at its own
  /// default `false` — which happens to equal `hasBadges`'s flipped value, so
  /// `--badges=false` still matches by coincidence. Symmetrically for the
  /// `hasTimestamps` test. The same blind spot applies to
  /// `hasSubMessages`↔`hasOutline`, any emote flag↔`hasTimestamps`/
  /// `hasOutline`, and any `true`-default flag↔`hasAlternateBackgrounds`.
  ///
  /// Rather than add a per-field test for every opposite-default pair — which
  /// only shrinks the blind spot to whatever pairs were enumerated — this
  /// pins each field to its own flag directly, closing the whole class:
  /// starting from an all-defaults request, flipping exactly one boolean
  /// field must change **exactly one** token in the emitted argv, and that
  /// token must be the flag this field owns. A swap between *any* two
  /// fields — same default or opposite — changes a *different* token (the
  /// other field's flag) instead of, or in addition to, changing nothing, so
  /// the symmetric-difference check below always disagrees with what a
  /// correct implementation would produce. Table-driven so a future boolean
  /// field is one row, not a new test.
  private struct BooleanFieldCase {
    let field: String
    let defaultToken: String
    let flippedToken: String
    let flip: (inout RenderRequest) -> Void
  }

  // `isSharpened` is the tenth `Bool` on `RenderRequest` and is deliberately
  // NOT a row here: it doesn't emit a `--flag=value` pair like the other
  // nine. It conditionally appends an entire `--input-args=...` string (the
  // unsharp filter), so flipping it produces one *added* token and zero
  // *removed* tokens — a shape this table's remove-one/add-one check can't
  // express. It already has its own dedicated coverage —
  // `sharpeningUsesUnsharpAndNeverSmartblur` and
  // `unsharpenedRenderDoesNotOverrideInputArgs`, below — including the GPL
  // rule that makes it matter. `boolFieldCountMatchesTableRowsPlusDocumentedExclusions`
  // enforces that this is the *only* exclusion: a future `Bool` field added
  // without either a row here or a documented exclusion like this one fails
  // that guard instead of silently widening the blind spot.
  private var booleanFieldCases: [BooleanFieldCase] {
    [
      BooleanFieldCase(field: "hasBadges", defaultToken: "--badges=true", flippedToken: "--badges=false") {
        $0.hasBadges = false
      },
      BooleanFieldCase(
        field: "hasTimestamps", defaultToken: "--timestamp=false", flippedToken: "--timestamp=true")
      {
        $0.hasTimestamps = true
      },
      BooleanFieldCase(
        field: "hasSubMessages", defaultToken: "--sub-messages=true", flippedToken: "--sub-messages=false")
      {
        $0.hasSubMessages = false
      },
      BooleanFieldCase(field: "hasOutline", defaultToken: "--outline=false", flippedToken: "--outline=true") {
        $0.hasOutline = true
      },
      BooleanFieldCase(
        field: "hasAlternateBackgrounds",
        defaultToken: "--alternate-backgrounds=false",
        flippedToken: "--alternate-backgrounds=true")
      {
        $0.hasAlternateBackgrounds = true
      },
      BooleanFieldCase(field: "isBTTVEnabled", defaultToken: "--bttv=true", flippedToken: "--bttv=false") {
        $0.isBTTVEnabled = false
      },
      BooleanFieldCase(field: "isFFZEnabled", defaultToken: "--ffz=true", flippedToken: "--ffz=false") {
        $0.isFFZEnabled = false
      },
      BooleanFieldCase(field: "isSTVEnabled", defaultToken: "--stv=true", flippedToken: "--stv=false") {
        $0.isSTVEnabled = false
      },
      BooleanFieldCase(
        field: "allowsUnlistedEmotes",
        defaultToken: "--allow-unlisted-emotes=true",
        flippedToken: "--allow-unlisted-emotes=false")
      {
        $0.allowsUnlistedEmotes = false
      },
    ]
  }

  @Test func flippingExactlyOneBooleanFieldChangesExactlyThatFieldsOwnFlagAndNoOther() {
    let baseline = args(.renderChat(RenderRequest(destination: URL(filePath: "/tmp/c.mp4"))))

    for testCase in booleanFieldCases {
      var request = RenderRequest(destination: URL(filePath: "/tmp/c.mp4"))
      testCase.flip(&request)
      let flipped = args(.renderChat(request))

      let onlyInBaseline = Set(baseline).subtracting(flipped)
      let onlyInFlipped = Set(flipped).subtracting(baseline)

      #expect(
        onlyInBaseline == [testCase.defaultToken],
        "flipping \(testCase.field) removed \(onlyInBaseline), expected only \(testCase.defaultToken)")
      #expect(
        onlyInFlipped == [testCase.flippedToken],
        "flipping \(testCase.field) added \(onlyInFlipped), expected only \(testCase.flippedToken)")
    }
  }

  /// Makes the table self-enforcing: without this, a `Bool` field added to
  /// `RenderRequest` six months from now with neither a row above nor a
  /// documented exclusion (like `isSharpened`'s, commented above
  /// `booleanFieldCases`) would silently widen the swap blind spot the
  /// table exists to close, and nothing would say so. `Mirror` over a
  /// default-constructed request counts every `Bool` stored property — the
  /// nine rows plus the one documented, named exclusion must account for all
  /// of them, or this fails and says exactly what changed.
  @Test func boolFieldCountMatchesTableRowsPlusDocumentedExclusions() {
    let documentedExclusions = 1 // isSharpened — see the comment above `booleanFieldCases`.
    let mirror = Mirror(reflecting: RenderRequest(destination: URL(filePath: "/tmp/c.mp4")))
    let boolFieldCount = mirror.children.filter { $0.value is Bool }.count

    let message = "RenderRequest has \(boolFieldCount) Bool fields but the table only accounts for "
      + "\(booleanFieldCases.count) rows + \(documentedExclusions) documented exclusion(s); "
      + "a Bool field was added without a row or a documented, counted exclusion"
    #expect(boolFieldCount == booleanFieldCases.count + documentedExclusions, "\(message)")
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
      hasAlternateBackgrounds: true,
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
