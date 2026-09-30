import Foundation
import Testing

@testable import OxbowKit

private func fixture() throws -> URL {
  try #require(Bundle.module.url(
    forResource: "chat-text-fixtures", withExtension: "json", subdirectory: "Fixtures"))
}

/// Runs a feed into a file, returning how many whole frames it wrote.
private func framesWritten(
  by feed: StandardInputFeed, frameBytes: Int, stop: StopFlag = StopFlag()) throws -> Int
{
  let url = URL(filePath: NSTemporaryDirectory()).appending(path: "oxbow-feed-\(UUID().uuidString)")
  FileManager.default.createFile(atPath: url.path, contents: nil)
  defer { try? FileManager.default.removeItem(at: url) }
  let handle = try FileHandle(forWritingTo: url)
  feed.write(handle, stop)
  try handle.close()
  let size = try #require(try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int)
  #expect(size % frameBytes == 0)
  return size / frameBytes
}

/// The chat for a composite, drawn straight into FFmpeg. docs/design/native-chat-render.md,
/// Phase 4.
@Suite("Native composite feed")
struct NativeCompositeFeedTests {

  // One frame a second keeps the fixture's 73 seconds to 73 small frames.
  private let request = RenderRequest(width: 60, height: 90, framerate: 1, fontSize: 15)
  private var frameBytes: Int { 60 * 90 * 4 }

  @Test func writesEveryFrameFromTheStart() throws {
    let feed = NativeChatRenderer.compositeFeed(chat: try fixture(), request: request, resumeFrom: nil)
    #expect(try framesWritten(by: feed, frameBytes: frameBytes) == 73)
  }

  /// A seek of the rendered file lands on the first frame at or after the resume point; the
  /// feed starts on that same frame. 70.5 s at 1 fps is frame 71, leaving 71 and 72.
  @Test func resumesAtTheFirstFrameAtOrAfterTheResumePoint() throws {
    let between = NativeChatRenderer.compositeFeed(
      chat: try fixture(), request: request, resumeFrom: .milliseconds(70_500))
    #expect(try framesWritten(by: between, frameBytes: frameBytes) == 2)
    let exact = NativeChatRenderer.compositeFeed(
      chat: try fixture(), request: request, resumeFrom: .seconds(70))
    #expect(try framesWritten(by: exact, frameBytes: frameBytes) == 3)
  }

  /// Resuming past the chat's end still sends one frame, the last, for `hstack` to hold: with
  /// no frames at all the composite exits 0 with an empty piece (resume.md §12).
  @Test func resumingPastTheEndSendsTheLastFrameOnce() throws {
    let feed = NativeChatRenderer.compositeFeed(
      chat: try fixture(), request: request, resumeFrom: .seconds(500))
    #expect(try framesWritten(by: feed, frameBytes: frameBytes) == 1)
  }

  @Test func writesNothingOnceStopped() throws {
    let stop = StopFlag()
    stop.set()
    let feed = NativeChatRenderer.compositeFeed(chat: try fixture(), request: request, resumeFrom: nil)
    #expect(try framesWritten(by: feed, frameBytes: frameBytes, stop: stop) == 0)
  }

  @Test func writesNothingForAFileThatIsNotChat() throws {
    let url = URL(filePath: NSTemporaryDirectory()).appending(path: "oxbow-not-chat-\(UUID().uuidString).json")
    try Data("{}".utf8).write(to: url)
    defer { try? FileManager.default.removeItem(at: url) }
    let feed = NativeChatRenderer.compositeFeed(chat: url, request: request, resumeFrom: nil)
    #expect(try framesWritten(by: feed, frameBytes: frameBytes) == 0)
  }
}

private func bundledFFmpeg() -> URL? {
  let path = URL(filePath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .appending(path: "build/ffmpeg/ffmpeg")
  return FileManager.default.fileExists(atPath: path.path) ? path : nil
}

/// The real composite arguments and a real feed through the bundled FFmpeg, from the start and
/// resumed. Skips when FFmpeg is absent — and then verifies nothing.
@Suite("Native composite end to end", .enabled(if: bundledFFmpeg() != nil))
struct NativeCompositeEndToEndTests {

  private let chat = RenderRequest(width: 100, height: 240, framerate: 30, fontSize: 15)

  /// Eight seconds of grey 320x240 at 30 fps, encoded the way a download arrives: h264 in MP4.
  private func source(in directory: URL, ffmpeg: URL) throws -> URL {
    let raw = directory.appending(path: "grey.rgba")
    try Data(repeating: 0x80, count: 320 * 240 * 4 * 240).write(to: raw)
    let video = directory.appending(path: "video.mp4")
    let encode = try ProcessSpawner.spawn(
      executable: ffmpeg,
      arguments: [
        "-v", "error", "-f", "rawvideo", "-pix_fmt", "rgba", "-video_size", "320x240",
        "-framerate", "30", "-i", raw.path, "-c:v", "h264_videotoolbox", "-b:v", "1M",
        "-pix_fmt", "yuv420p", video.path,
      ],
      workingDirectory: directory)
    _ = encode.stdout.readDataToEndOfFile()
    #expect(ProcessSpawner.wait(encode.pid) == .exited(0))
    return video
  }

  /// The fixture's chat, cut to the source's eight seconds, as a trimmed download would be.
  private func chatFile(in directory: URL) throws -> URL {
    let url = directory.appending(path: "chat.json")
    let json = try String(contentsOf: try fixture(), encoding: .utf8)
      .replacingOccurrences(of: "\"end\": 73", with: "\"end\": 8")
    try json.write(to: url, atomically: true, encoding: .utf8)
    return url
  }

  private func composite(
    resumeFrom: Duration?, in directory: URL, ffmpeg: URL) async throws -> (RunResult, URL)
  {
    let video = try source(in: directory, ffmpeg: ffmpeg)
    let chatJSON = try chatFile(in: directory)
    let output = directory.appending(path: "piece.mp4")
    let request = CompositeRequest(
      framerate: 30, duration: .seconds(8), destination: directory.appending(path: "out.mp4"),
      chat: chat)
    let context = StepContext(
      stepTempDirectory: directory, outputFile: output, ffmpegPath: ffmpeg,
      inputArtifacts: [video, chatJSON], resumeFrom: resumeFrom)
    let launch = Launch(
      executable: ffmpeg,
      arguments: ArgumentBuilder.arguments(for: .composite(request), context: context),
      workingDirectory: directory, dialect: .ffmpeg(duration: .seconds(8)),
      standardInput: NativeChatRenderer.compositeFeed(
        chat: chatJSON, request: chat, resumeFrom: resumeFrom))
    let result = try await HelperProcess().run(launch) { _ in }
    return (result, output)
  }

  /// Width, height and frame count of the first video stream, by decoding every frame.
  private func probe(_ file: URL, ffmpeg: URL) throws -> (size: String, frames: Int) {
    let decode = try ProcessSpawner.spawn(
      executable: ffmpeg, arguments: ["-v", "error", "-i", file.path, "-f", "framemd5", "-"],
      workingDirectory: file.deletingLastPathComponent())
    let hashes = String(decoding: decode.stdout.readDataToEndOfFile(), as: UTF8.self)
    #expect(ProcessSpawner.wait(decode.pid) == .exited(0))
    let size = hashes.split(separator: "\n").first { $0.hasPrefix("#dimensions") }
      .map { String($0.split(separator: " ").last ?? "") } ?? ""
    return (size, hashes.split(separator: "\n").filter { !$0.hasPrefix("#") }.count)
  }

  private func scratch() throws -> URL {
    let directory = URL(filePath: NSTemporaryDirectory()).appending(path: "oxbow-composite-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
  }

  @Test func stacksTheDrawnChatBesideTheVideo() async throws {
    let ffmpeg = try #require(bundledFFmpeg())
    let directory = try scratch()
    defer { try? FileManager.default.removeItem(at: directory) }

    let (result, output) = try await composite(resumeFrom: nil, in: directory, ffmpeg: ffmpeg)

    #expect(result.status == .exited(0), "\(result.standardError)")
    let decoded = try probe(output, ffmpeg: ffmpeg)
    #expect(decoded.size == "420x240")
    #expect(decoded.frames == 240)
  }

  /// Resumed six seconds in, the piece is the last two seconds of both columns.
  @Test func resumesPartWayThrough() async throws {
    let ffmpeg = try #require(bundledFFmpeg())
    let directory = try scratch()
    defer { try? FileManager.default.removeItem(at: directory) }

    let (result, output) = try await composite(resumeFrom: .seconds(6), in: directory, ffmpeg: ffmpeg)

    #expect(result.status == .exited(0), "\(result.standardError)")
    let decoded = try probe(output, ffmpeg: ffmpeg)
    #expect(decoded.size == "420x240")
    #expect(abs(decoded.frames - 60) <= 1)
  }
}
