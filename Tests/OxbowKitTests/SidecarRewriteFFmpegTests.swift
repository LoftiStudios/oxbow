import Foundation
import Testing
@testable import OxbowKit

/// Whether `build/ffmpeg/ffmpeg` exists in this checkout. Building it needs
/// its own toolchain (`./scripts/build-ffmpeg.sh`), which UI-only work does
/// not require (CLAUDE.md: "Building without build/helper or build/ffmpeg
/// succeeds with a warning") — so the default `swift test` run must not fail
/// outright when it is missing. This suite is `.enabled(if:)`-gated on it
/// below and skips cleanly instead.
private func bundledFFmpegExists() -> Bool {
  FileManager.default.fileExists(atPath: SidecarRewriteFFmpegTests.ffmpegPath.path)
}

/// Proves, against the real bundled FFmpeg, the one claim
/// `docs/design/resume.md` §4's sidecar fix actually rests on and that no
/// other test exercises: that on a resume, mapping the sidecar's audio from
/// the **third, un-seeked** input produces a sidecar spanning the **whole
/// source**, not just the tail from the resume point. `ArgumentBuilderTests`
/// proves the argv has the right *shape* (a third input, `2:a:0?`, no `-ss`
/// on it) — but the argv was never what broke; the original defect was a
/// gate that skipped the sidecar entirely, and the fix's claim about what
/// `-ss`-free mapping actually *does* is a statement about FFmpeg's own
/// behaviour, which only running FFmpeg can confirm.
///
/// **Deliberately in the default suite, not behind `OXBOW_RESUME_E2E=1`.**
/// That gate exists for real network access and multi-minute real encodes;
/// this needs neither. The synthetic source below is built entirely from the
/// bundled FFmpeg's own demuxers and encoders — no `lavfi`, `testsrc`, or
/// `sine`, none of which exist even in the full build (see `docs/ffmpeg.md`)
/// — by feeding black frames from `/dev/zero` through `rawvideo`, the same
/// technique `Tests/OxbowKitTests/Fixtures/fragmented-3-frames.mp4`
/// established for a video-only fixture, and silence through `wav`. Both of
/// those demuxers are in the `MINIMAL=1` component list as well as the full
/// one, so this holds against either build variant; `writeSilentWAV` below
/// records why the audio track cannot simply be `/dev/zero` too.
///
/// One short `h264_videotoolbox`/`aac` encode of a few seconds of silence and
/// black frames costs a fraction of a second — this runs the real composite
/// argv through the real bundled binary and is still no slower than the
/// fixture-based tests around it. It needs the bundled FFmpeg binary, though,
/// which the default suite otherwise never touches, so the whole suite is
/// skipped — not failed — when it is absent. The run stays green either way,
/// and no CI job that runs the OxbowKit suite has the binary, so
/// `docs/development.md` records where this does run and how to run it
/// yourself before trusting a green result.
@Suite("Sidecar rewrite spans the whole source", .enabled(if: bundledFFmpegExists()))
struct SidecarRewriteFFmpegTests {

  private struct TestError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
  }

  static let ffmpegPath: URL = {
    URL(filePath: #filePath)
      .deletingLastPathComponent()  // Tests/OxbowKitTests/
      .deletingLastPathComponent()  // Tests/
      .deletingLastPathComponent()  // repo root
      .appending(path: "build/ffmpeg/ffmpeg")
  }()

  /// Runs `arguments` against the bundled FFmpeg and waits for it to finish.
  /// Stdout and stderr share one pipe — there is no stdin to feed and every
  /// output here is at most a few KB, so a single synchronous drain cannot
  /// deadlock the way an unread pipe against a live process normally could.
  private func run(_ arguments: [String], in directory: URL) throws -> (status: Int32, output: String) {
    let process = Process()
    process.executableURL = Self.ffmpegPath
    process.arguments = arguments
    process.currentDirectoryURL = directory
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    try process.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return (process.terminationStatus, String(decoding: data, as: UTF8.self))
  }

  /// The final `time=HH:MM:SS.ss` FFmpeg's default stats line reports for a
  /// pass over `file` — the same technique `ResumeEndToEndTests.finalTime`
  /// uses against the real VOD, reimplemented locally so this suite has no
  /// dependency on that one and can be `.enabled(if:)`-gated independently.
  ///
  /// `-c copy` rather than a decode. Writing to `-f null` otherwise picks the
  /// null muxer's default encoder for the stream, which for AAC audio is
  /// `pcm_s16le` — a *decoder* in the `MINIMAL=1` set but not an encoder, so
  /// the measurement failed there on a file the composite had just written
  /// perfectly well. Stream copy needs no encoder at all, reads the same
  /// packet timestamps, and is the cheaper of the two.
  private func duration(of file: URL, scratch: URL) throws -> Double {
    let result = try run(["-hide_banner", "-i", file.path, "-c", "copy", "-f", "null", "-"], in: scratch)
    guard result.status == 0 else {
      throw TestError("measuring \(file.lastPathComponent) failed (\(result.status)):\n\(result.output)")
    }
    let pattern = #"time=\s*(\d+):(\d+):(\d+\.\d+)"#
    let regex = try NSRegularExpression(pattern: pattern)
    let matches = regex.matches(in: result.output, range: NSRange(result.output.startIndex..., in: result.output))
    guard let last = matches.last,
          let hRange = Range(last.range(at: 1), in: result.output), let h = Double(result.output[hRange]),
          let mRange = Range(last.range(at: 2), in: result.output), let m = Double(result.output[mRange]),
          let sRange = Range(last.range(at: 3), in: result.output), let s = Double(result.output[sRange])
    else { throw TestError("no time= measuring \(file.lastPathComponent):\n\(result.output.suffix(1000))") }
    return h * 3600 + m * 60 + s
  }

  /// Writes `seconds` of 44.1 kHz mono silence as a WAV file.
  ///
  /// The audio has to reach FFmpeg through a demuxer that the `MINIMAL=1`
  /// component set in `scripts/build-ffmpeg.sh` also has. Raw PCM straight
  /// from `/dev/zero` needs `-f s16le`, and `s16le` is absent from that
  /// build's `--enable-demuxer` list — so the video half of this source built
  /// fine there while the audio half failed with `Unknown input format`.
  /// `wav` is on the list, and prefixing the same zero bytes with a 44-byte
  /// RIFF header yields the identical silent `pcm_s16le` track through a
  /// demuxer both variants ship. Adding `s16le` to that list would have
  /// worked too, but `docs/ffmpeg.md` §2 keeps the minimal set derived from
  /// what Oxbow actually invokes, and a test is not a reason to widen it.
  ///
  /// The header also carries the rate, channel count and length, so this
  /// input needs no `-f`, `-ar`, `-ac` or `-t` of its own.
  private func writeSilentWAV(seconds: Double, to url: URL) throws {
    let sampleRate = 44100
    let bytesPerSample = 2  // pcm_s16le, one channel
    let dataBytes = Int(Double(sampleRate) * seconds) * bytesPerSample

    var header = Data()
    func append(_ value: some FixedWidthInteger) {
      withUnsafeBytes(of: value.littleEndian) { header.append(contentsOf: $0) }
    }
    func append(_ ascii: String) { header.append(contentsOf: Array(ascii.utf8)) }

    append("RIFF")
    append(UInt32(36 + dataBytes))  // everything in the file after this field
    append("WAVEfmt ")
    append(UInt32(16))  // fmt chunk size
    append(UInt16(1))  // PCM, uncompressed
    append(UInt16(1))  // mono
    append(UInt32(sampleRate))
    append(UInt32(sampleRate * bytesPerSample))  // byte rate
    append(UInt16(bytesPerSample))  // block align
    append(UInt16(8 * bytesPerSample))  // bits per sample
    append("data")
    append(UInt32(dataBytes))

    try (header + Data(count: dataBytes)).write(to: url)
  }

  @Test func aResumedSidecarSpansTheWholeSourceNotTheTail() throws {
    let scratch = URL(filePath: NSTemporaryDirectory())
      .appending(path: "oxbow-sidecar-ffmpeg-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: scratch) }

    // A synthetic source with both a video and an audio track, entirely from
    // the bundled FFmpeg's own component set: black yuv420p frames read
    // straight from /dev/zero and capped by the output -t, and silence from a
    // WAV whose own header already fixes its length at sourceDuration.
    let sourceDuration = 6.0
    let silence = scratch.appending(path: "silence.wav")
    try writeSilentWAV(seconds: sourceDuration, to: silence)
    let source = scratch.appending(path: "source.mp4")
    let build = try run([
      "-y", "-hide_banner", "-loglevel", "error",
      "-f", "rawvideo", "-pix_fmt", "yuv420p", "-s", "64x64", "-r", "10",
      "-i", "/dev/zero",
      "-i", silence.path,
      "-t", "\(sourceDuration)",
      "-c:v", "h264_videotoolbox", "-b:v", "200k", "-pix_fmt", "yuv420p",
      "-c:a", "aac", "-b:a", "64k",
      "-movflags", "+faststart",
      source.path,
    ], in: scratch)
    try #require(build.status == 0, Comment(rawValue: "synthetic source build failed:\n\(build.output)"))

    // The exact argv a resumed composite emits: `ArgumentBuilder`, not a
    // hand-rolled command — this is what actually ships, not a re-statement
    // of it. Both composited inputs are the same synthetic file, seeked to
    // the resume point; the video and chat render are ordinarily different
    // files, but `ArgumentBuilder` never inspects their contents, only their
    // position, so reusing one file for both is faithful to the real argv
    // shape without needing a second synthesized track.
    let resumeSeconds = 4.0
    let tailDuration = sourceDuration - resumeSeconds  // 2s — what a wrongly-seeked sidecar would be capped at
    let pieceOutput = scratch.appending(path: "piece.mp4")
    let context = StepContext(
      stepTempDirectory: scratch,
      outputFile: pieceOutput,
      ffmpegPath: Self.ffmpegPath,
      inputArtifacts: [source, source],
      resumeFrom: .seconds(resumeSeconds),
      hasUsableSidecar: false)
    let request = CompositeRequest(
      framerate: 10, duration: .seconds(sourceDuration), destination: pieceOutput)
    let arguments = ArgumentBuilder.arguments(for: .composite(request), context: context)

    // Same shape `ArgumentBuilderTests` already asserts on synthetic paths —
    // restated here as a precondition, not a duplicate: if this ever stops
    // holding, the run below would be testing the wrong thing.
    try #require(arguments.contains("2:a:0?"), "expected a resumed rewrite to map from the third input")
    let inputIndices = arguments.indices.filter { arguments[$0] == "-i" }
    try #require(inputIndices.count == 3, "expected video, chat, and a third un-seeked copy")
    try #require(arguments[inputIndices[2] - 1] != "-ss", "the third input must be un-seeked")

    let run1 = try run(arguments, in: scratch)
    try #require(run1.status == 0, Comment(rawValue: "resumed composite failed:\n\(run1.output)"))

    let sidecar = scratch.appending(path: "audio.m4a")
    try #require(FileManager.default.fileExists(atPath: sidecar.path), "no sidecar was written")
    #expect(try FragmentedMP4.hasCompleteMoov(at: sidecar), "a finished stream copy must have a complete moov")

    let sidecarDuration = try duration(of: sidecar, scratch: scratch)
    print("Synthetic source: \(sourceDuration)s. Resume point: \(resumeSeconds)s (tail \(tailDuration)s). "
      + "Rewritten sidecar: \(sidecarDuration)s.")

    // The claim under test. A sidecar mapped from the wrongly-seeked input 0
    // would top out around `tailDuration` (2s here) — worse than the original
    // corruption, since §4 explains it would desync silently instead of
    // failing loudly. A correct, un-seeked-third-input sidecar runs to the
    // full source.
    #expect(sidecarDuration > sourceDuration - 0.5,
            Comment(rawValue: "sidecar (\(sidecarDuration)s) must cover the whole \(sourceDuration)s "
              + "source, not just what survived the resume seek"))
    #expect(sidecarDuration > tailDuration + 1,
            Comment(rawValue: "sidecar (\(sidecarDuration)s) is no longer than the \(tailDuration)s tail "
              + "a wrongly-seeked mapping would have produced — this would mean the fix regressed to "
              + "truncating the sidecar, which resume.md §4 says is worse than leaving it corrupt"))
  }
}
