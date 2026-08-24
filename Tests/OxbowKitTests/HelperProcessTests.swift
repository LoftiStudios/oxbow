import Foundation
import Testing
@testable import OxbowKit

@Suite("HelperProcess", .serialized)
struct HelperProcessTests {

  private func script(_ body: String) throws -> Launch {
    let directory = URL(filePath: NSTemporaryDirectory())
      .appending(path: "oxbow-helper-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = directory.appending(path: "fixture.sh")
    try "#!/bin/sh\n\(body)\n".write(to: url, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    return Launch(executable: url, arguments: [], workingDirectory: directory)
  }

  /// Progress must arrive incrementally, and `\r`-delimited output must be
  /// recovered exactly as it is from the real CLI.
  @Test func streamsParsedProgressWhileRunning() async throws {
    let launch = try script(#"printf '[STATUS] - Downloading 50%%\r[STATUS] - Downloading 100%% [1/1]\n'"#)

    let collected = Collected()
    let process = HelperProcess()
    let result = try await process.run(launch) { await collected.append($0) }

    let lines = await collected.lines
    #expect(result.status == .exited(0))
    #expect(lines.count == 2)
    if case .status(let last) = lines[1] {
      #expect(last.fraction == 1.0)
      #expect(last.index == 1)
    } else {
      Issue.record("expected a status line")
    }
  }

  @Test func capturesStandardErrorSeparately() async throws {
    let launch = try script("echo boom >&2; exit 134")
    let result = try await HelperProcess().run(launch) { _ in }

    #expect(result.status == .exited(134))
    #expect(result.standardError.contains("boom"))
  }

  /// Cancellation must reach a grandchild, and must not hang.
  @Test func cancellationTerminatesTheProcessGroup() async throws {
    let launch = try script("sleep 300 & sleep 300")
    let process = HelperProcess()

    let running = Task { try await process.run(launch) { _ in } }
    try await Task.sleep(for: .milliseconds(300))
    await process.cancel()

    let result = try await running.value
    #expect(result.status == .signalled(SIGTERM) || result.status == .signalled(SIGKILL))
  }
}

/// Actor so the output callback can accumulate across concurrency domains.
actor Collected {
  private(set) var lines: [ParsedLine] = []
  func append(_ line: ParsedLine) { lines.append(line) }
}
