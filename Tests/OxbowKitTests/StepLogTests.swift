import Foundation
import Testing
@testable import OxbowKit

@Suite("Step log")
struct StepLogTests {

  private func temporaryFile() -> URL {
    URL(filePath: NSTemporaryDirectory())
      .appending(path: "oxbow-log-\(UUID().uuidString)")
      .appending(path: "step.log")
  }

  @Test func readingALogThatWasNeverWrittenIsEmpty() async {
    let log = StepLog(fileURL: temporaryFile())
    #expect(await log.tail() == "")
  }

  @Test func appendedLinesComeBackInOrder() async {
    let url = temporaryFile()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let log = StepLog(fileURL: url)

    await log.append("first")
    await log.append("second")

    #expect(await log.tail() == "first\nsecond\n")
  }

  @Test func createsTheContainingDirectory() async {
    let url = temporaryFile()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let log = StepLog(fileURL: url)

    await log.append("x")

    #expect(FileManager.default.fileExists(atPath: url.path))
  }

  /// The end of the output is what says where a step got to; the beginning is
  /// banner noise. A cap therefore has to drop the head, not refuse to write.
  @Test func exceedingTheCapKeepsTheTailAndDropsTheHead() async {
    let url = temporaryFile()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let log = StepLog(fileURL: url, maxBytes: 200)

    for index in 0..<200 { await log.append("line \(index)") }

    let tail = await log.tail()
    #expect(!tail.contains("line 0\n"), "the head should have been dropped")
    #expect(tail.contains("line 199"), "the most recent line must survive")
    #expect(tail.utf8.count <= 200, "cap exceeded: \(tail.utf8.count) bytes")
  }

  /// Dropping bytes rather than lines would leave a mangled first line like
  /// "ne 47", which reads as corruption to whoever opens the log.
  @Test func compactionNeverLeavesAPartialFirstLine() async {
    let url = temporaryFile()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let log = StepLog(fileURL: url, maxBytes: 200)

    for index in 0..<200 { await log.append("line \(index)") }

    let first = await log.tail().split(separator: "\n").first.map(String.init) ?? ""
    #expect(first.hasPrefix("line "), "first line was mangled: \(first)")
  }

  @Test func tailCanBeLimitedToARecentNumberOfLines() async {
    let url = temporaryFile()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let log = StepLog(fileURL: url)

    for index in 0..<10 { await log.append("line \(index)") }

    let recent = await log.tail(lines: 3)
    #expect(recent == "line 7\nline 8\nline 9\n")
  }

  /// A step keeps writing while the UI reads to draw a disclosure, so reading
  /// must not disturb the writer's position.
  @Test func readingDoesNotDisturbSubsequentAppends() async {
    let url = temporaryFile()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let log = StepLog(fileURL: url)

    await log.append("before")
    _ = await log.tail()
    await log.append("after")

    #expect(await log.tail() == "before\nafter\n")
  }
}
