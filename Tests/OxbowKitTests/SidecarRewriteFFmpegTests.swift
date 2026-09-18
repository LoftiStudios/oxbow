import Foundation
import Testing
@testable import OxbowKit

/// Skip when bundled FFmpeg is absent so UI-only checkouts can run the package suite.
private func bundledFFmpegExists() -> Bool {
  FileManager.default.fileExists(atPath: SidecarRewriteFFmpegTests.ffmpegPath.path)
}

/// Runs real resumed-composite arguments against bundled FFmpeg and proves rewritten audio
/// spans the full source. Synthetic black frames and WAV silence work with both full and
/// minimal builds, without network or lavfi. Skips when FFmpeg is absent; a green skipped run
/// does not verify this behavior.
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

  /// Capture both output streams into one drained pipe, avoiding an undrained second pipe.
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

  /// Measure final packet time with stream copy. Decoding to the null muxer would require the
  /// PCM encoder absent from the minimal build.
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

  /// Writes 44.1 kHz mono silent WAV. The minimal build includes the WAV demuxer but not raw
  /// s16le; the header also supplies rate, channels, and duration without extra input
  /// arguments.
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

    // Black rawvideo plus silent WAV uses components present in both FFmpeg build variants.
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

    // Use production ArgumentBuilder output. Reuse the synthetic file for video/chat inputs;
    // their positions and seek arguments match the real invocation.
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

    // Verify the intended unseeked-sidecar argument shape before executing it.
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

    // Sidecar duration must reach the full source, not the two-second resumed tail.
    #expect(sidecarDuration > sourceDuration - 0.5,
            Comment(rawValue: "sidecar (\(sidecarDuration)s) must cover the whole \(sourceDuration)s "
              + "source, not just what survived the resume seek"))
    #expect(sidecarDuration > tailDuration + 1,
            Comment(rawValue: "sidecar (\(sidecarDuration)s) is no longer than the \(tailDuration)s tail "
              + "a wrongly-seeked mapping would have produced — this would mean the fix regressed to "
              + "truncating the sidecar, which resume.md §4 says is worse than leaving it corrupt"))
  }
}
