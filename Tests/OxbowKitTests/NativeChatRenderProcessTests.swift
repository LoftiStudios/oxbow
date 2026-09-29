import Darwin
import Foundation
import Testing

@testable import OxbowKit

@Suite("Native chat render process")
struct NativeChatRenderProcessTests {

  private let output = URL(filePath: "/tmp/render.mp4")

  /// Our LGPL FFmpeg has VideoToolbox and not libx264, and `unsharp` and not `smartblur`: the
  /// same two rules `ArgumentBuilder` enforces for the CLI's render.
  @Test func encodesAsTheCLIIsAskedTo() {
    let arguments = NativeChatRenderProcess.encoderArguments(
      for: RenderRequest(width: 342, height: 1026, framerate: 30, bitrateMbps: 12), output: output)
    #expect(arguments.suffix(7) == [
      "-c:v", "h264_videotoolbox", "-b:v", "12M", "-pix_fmt", "yuv420p", "/tmp/render.mp4",
    ])
    #expect(arguments.contains("342x1026"))
    #expect(!arguments.contains { $0.contains("libx264") || $0.contains("smartblur") })
    #expect(!arguments.contains("-vf"))
  }

  @Test func sharpensWithUnsharp() throws {
    let arguments = NativeChatRenderProcess.encoderArguments(
      for: RenderRequest(isSharpened: true), output: output)
    let filter = try #require(arguments.firstIndex(of: "-vf"))
    #expect(arguments[filter + 1] == "unsharp=5:5:1.0")
  }
}

@Suite("Process spawner standard input")
struct ProcessSpawnerStandardInputTests {

  /// What goes in comes out, and closing our end gives the child EOF.
  @Test func pipesStandardInputToTheChild() async throws {
    let spawned = try ProcessSpawner.spawn(
      executable: URL(filePath: "/bin/cat"), arguments: [],
      workingDirectory: URL(filePath: NSTemporaryDirectory()), standardInput: true)
    let stdin = try #require(spawned.stdin)
    try stdin.write(contentsOf: Data("frames".utf8))
    try stdin.close()
    let echoed = spawned.stdout.readDataToEndOfFile()
    #expect(String(decoding: echoed, as: UTF8.self) == "frames")
    #expect(ProcessSpawner.wait(spawned.pid) == .exited(0))
  }

  @Test func leavesStandardInputAloneUnlessAsked() throws {
    let spawned = try ProcessSpawner.spawn(
      executable: URL(filePath: "/usr/bin/true"), arguments: [],
      workingDirectory: URL(filePath: NSTemporaryDirectory()))
    #expect(spawned.stdin == nil)
    #expect(ProcessSpawner.wait(spawned.pid) == .exited(0))
  }
}

private func bundledFFmpeg() -> URL? {
  let path = URL(filePath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .appending(path: "build/ffmpeg/ffmpeg")
  return FileManager.default.fileExists(atPath: path.path) ? path : nil
}

/// A real native render through the bundled FFmpeg. Skips when FFmpeg is absent, like the
/// sidecar suite — and like it, a green skipped run verifies nothing.
@Suite("Native chat render end to end", .enabled(if: bundledFFmpeg() != nil))
struct NativeChatRenderEndToEndTests {

  private func fixture() throws -> URL {
    try #require(Bundle.module.url(
      forResource: "chat-text-fixtures", withExtension: "json", subdirectory: "Fixtures"))
  }

  @Test func writesEveryFrameTheCLIWouldAsPlayableH264() async throws {
    let ffmpeg = try #require(bundledFFmpeg())
    let directory = URL(filePath: NSTemporaryDirectory()).appending(path: "oxbow-native-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let output = directory.appending(path: "render.mp4")
    let request = RenderRequest(width: 342, height: 1026, framerate: 30, fontSize: 15, bitrateMbps: 12)

    let process = NativeChatRenderProcess(
      request: request, input: try fixture(), output: output, ffmpeg: ffmpeg)
    let phases = Phases()
    let result = try await process.run(
      Launch(executable: ffmpeg, arguments: [], workingDirectory: directory)) { line in
        if case .status(let progress) = line { await phases.add(progress.phase) }
      }

    #expect(result.status == .exited(0), "\(result.standardError)")
    #expect(await phases.seen == ["Fetching Images", "Rendering Video"])

    // Decode every frame: the count is the CLI's for this file (73 s at 30 fps).
    let decode = try ProcessSpawner.spawn(
      executable: ffmpeg, arguments: ["-v", "error", "-i", output.path, "-f", "framemd5", "-"],
      workingDirectory: directory)
    let hashes = String(decoding: decode.stdout.readDataToEndOfFile(), as: UTF8.self)
    #expect(ProcessSpawner.wait(decode.pid) == .exited(0))
    #expect(hashes.split(separator: "\n").filter { !$0.hasPrefix("#") }.count == 2190)
  }

  @Test func cancellingBeforeRunningNeverStartsFFmpeg() async throws {
    let ffmpeg = try #require(bundledFFmpeg())
    let directory = URL(filePath: NSTemporaryDirectory())
    let output = directory.appending(path: "oxbow-never-\(UUID().uuidString).mp4")
    let process = NativeChatRenderProcess(
      request: RenderRequest(), input: try fixture(), output: output, ffmpeg: ffmpeg)
    await process.cancel()
    let result = try await process.run(
      Launch(executable: ffmpeg, arguments: [], workingDirectory: directory)) { _ in }
    #expect(result.status == .signalled(SIGKILL))
    #expect(!FileManager.default.fileExists(atPath: output.path))
  }

  /// Ten minutes of chat is 18,000 frames, seconds of work: cancelling a moment in has to stop
  /// it well short of the end, with FFmpeg signalled rather than finishing cleanly.
  @Test func cancellingMidRenderStopsIt() async throws {
    let ffmpeg = try #require(bundledFFmpeg())
    let directory = URL(filePath: NSTemporaryDirectory()).appending(path: "oxbow-native-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let long = directory.appending(path: "long.json")
    var json = try String(contentsOf: try fixture(), encoding: .utf8)
    json = json.replacingOccurrences(of: "\"end\": 73", with: "\"end\": 600")
    try json.write(to: long, atomically: true, encoding: .utf8)

    let process = NativeChatRenderProcess(
      request: RenderRequest(width: 342, height: 1026, framerate: 30, fontSize: 15),
      input: long, output: directory.appending(path: "render.mp4"), ffmpeg: ffmpeg)
    let furthest = Furthest()
    let run = Task {
      try await process.run(Launch(executable: ffmpeg, arguments: [], workingDirectory: directory)) { line in
        if case .status(let progress) = line, progress.phase == "Rendering Video" {
          await furthest.record(progress.fraction ?? 0)
        }
      }
    }
    try await Task.sleep(for: .milliseconds(500))
    await process.cancel()
    let result = try await run.value
    #expect(result.status != .exited(0))
    #expect(await furthest.value < 1)
  }

  private actor Furthest {
    private(set) var value = 0.0
    func record(_ fraction: Double) { value = max(value, fraction) }
  }

  private actor Phases {
    private(set) var seen: [String] = []
    func add(_ phase: String?) {
      guard let phase, seen.last != phase else { return }
      seen.append(phase)
    }
  }
}
