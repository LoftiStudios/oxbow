import Foundation
import Testing
@testable import OxbowKit

/// Against a real MetricKit payload: a 0.5.0 build that trapped because its
/// subscriber was main-actor isolated and MetricKit delivers on a background
/// queue.
@Suite("Crash report")
struct CrashReportTests {

  private func fixture() throws -> CrashReport {
    let url = try #require(Bundle.module.url(
      forResource: "metrickit-crash", withExtension: "json", subdirectory: "Fixtures"))
    return try #require(CrashReport(json: Data(contentsOf: url)))
  }

  @Test func readsTheMetadata() throws {
    let report = try fixture()
    #expect(report.appVersion == "0.5.0")
    #expect(report.appBuild == "147")
    #expect(report.osVersion == "macOS 27.0 (26A428)")
    #expect(report.summary == "EXC_BREAKPOINT (SIGTRAP)")
    #expect(report.terminationReason == "Namespace SIGNAL, Code 0x5")
    #expect(report.exceptionMessage == nil)
  }

  /// The attributed thread is the eighth of thirteen, so taking the first
  /// stack would report an idle thread.
  @Test func followsTheCrashedThreadInnermostFirst() throws {
    let report = try fixture()
    #expect(report.frames.first?.binaryName == "libdispatch.dylib")
    #expect(report.frames.first?.offset == 227972)
    let own = report.frames.filter { $0.binaryName == "Oxbow" }
    #expect(own.count == 2)
    #expect(own.first?.binaryUUID == "8C3A5A96-07E1-33FD-96E8-5DE188DD38B8")
    #expect(own.first?.offset == 50488)
  }

  @Test func refusesWhatIsNotADiagnostic() {
    #expect(CrashReport(json: Data("{}".utf8)) == nil)
    #expect(CrashReport(json: Data("not json".utf8)) == nil)
  }

  @Test func namesWhatItDoesNotKnowByNumber() throws {
    let json = """
      {"callStackTree": {"callStacks": []},
       "diagnosticMetaData": {"exceptionType": 99, "signal": 31}}
      """
    let report = try #require(CrashReport(json: Data(json.utf8)))
    #expect(report.summary == "exception 99 (signal 31)")
    #expect(report.frames.isEmpty)
    #expect(report.appVersion == "unknown")
  }

  @Test func quotesAnExceptionMessage() throws {
    let json = """
      {"callStackTree": {"callStacks": []},
       "diagnosticMetaData": {"exceptionType": 10, "signal": 6,
         "exceptionReason": {"composedMessage": "index 3 beyond bounds"}}}
      """
    let report = try #require(CrashReport(json: Data(json.utf8)))
    #expect(report.summary == "EXC_CRASH (SIGABRT)")
    #expect(CrashIssue.body(for: report).contains("> index 3 beyond bounds"))
  }

  @Test func summarisesWithWhatIsPresent() throws {
    let signalOnly = """
      {"callStackTree": {"callStacks": []}, "diagnosticMetaData": {"signal": 11}}
      """
    #expect(try #require(CrashReport(json: Data(signalOnly.utf8))).summary == "SIGSEGV")
    let exceptionOnly = """
      {"callStackTree": {"callStacks": []}, "diagnosticMetaData": {"exceptionType": 1}}
      """
    #expect(try #require(CrashReport(json: Data(exceptionOnly.utf8))).summary == "EXC_BAD_ACCESS")
    let neither = """
      {"callStackTree": {"callStacks": []}, "diagnosticMetaData": {}}
      """
    #expect(try #require(CrashReport(json: Data(neither.utf8))).summary == "Crash")
  }
}

@Suite("Crash issue link")
struct CrashIssueTests {

  private func fixture() throws -> CrashReport {
    let url = try #require(Bundle.module.url(
      forResource: "metrickit-crash", withExtension: "json", subdirectory: "Fixtures"))
    return try #require(CrashReport(json: Data(contentsOf: url)))
  }

  private func query(_ url: URL) -> [String: String] {
    let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
    return Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
  }

  @Test func opensANewIssueOnTheRepository() throws {
    let url = CrashIssue.url(for: try fixture())
    #expect(url.absoluteString.hasPrefix("https://github.com/LoftiStudios/oxbow/issues/new?"))
    #expect(query(url)["title"] == "Crash in Oxbow 0.5.0: EXC_BREAKPOINT (SIGTRAP)")
  }

  @Test func carriesTheTraceAndTheUUIDTheDSYMIsMatchedBy() throws {
    let body = try #require(query(CrashIssue.url(for: try fixture()))["body"])
    #expect(body.contains("Oxbow 0.5.0 (147) · macOS 27.0 (26A428)"))
    #expect(body.contains("libdispatch.dylib"))
    #expect(body.contains("+ 50488"))
    #expect(body.contains("`8C3A5A96-07E1-33FD-96E8-5DE188DD38B8`"))
  }

  /// A bare `+` in a query string reads as a space on GitHub's side.
  @Test func encodesThePlusSigns() throws {
    let url = CrashIssue.url(for: try fixture())
    #expect(!(url.query(percentEncoded: true) ?? "").contains("+"))
  }

  @Test func dropsOuterFramesToFitTheLimit() throws {
    let report = try fixture()
    let full = CrashIssue.url(for: report, maximumLength: .max)
    let limit = full.absoluteString.count - 200
    let trimmed = CrashIssue.url(for: report, maximumLength: limit)
    #expect(trimmed.absoluteString.count <= limit)
    let body = try #require(query(trimmed)["body"])
    #expect(body.contains("more frames"))
    // The innermost frame survives; it is the one that matters most.
    #expect(body.contains("+ 227972"))
  }

  /// scripts/symbolicate-crash.py parses this body, and its own test reads the
  /// same file, so a change to the format has to change both deliberately.
  /// Regenerate with OXBOW_WRITE_GOLDEN=1.
  @Test func matchesTheBodyTheSymbolicatorParses() throws {
    let body = CrashIssue.body(for: try fixture())
    let url = try #require(Bundle.module.url(
      forResource: "crash-issue-body", withExtension: "md", subdirectory: "Fixtures"))
    if ProcessInfo.processInfo.environment["OXBOW_WRITE_GOLDEN"] == "1" {
      let source = URL(filePath: #filePath).deletingLastPathComponent()
        .appending(path: "Fixtures/crash-issue-body.md")
      try body.write(to: source, atomically: true, encoding: .utf8)
    }
    #expect(body == (try String(contentsOf: url, encoding: .utf8)))
  }

  @Test func keepsASpaceAfterThreeDigitFrameNumbers() throws {
    let frame = """
      {"binaryName": "Oxbow", "binaryUUID": "U", "offsetIntoBinaryTextSegment": 1}
      """
    var chain = frame
    for _ in 0..<100 {
      chain = """
        {"binaryName": "Oxbow", "binaryUUID": "U", "offsetIntoBinaryTextSegment": 1,
         "subFrames": [\(chain)]}
        """
    }
    let json = """
      {"callStackTree": {"callStacks": [{"threadAttributed": true,
        "callStackRootFrames": [\(chain)]}]}, "diagnosticMetaData": {}}
      """
    let report = try #require(CrashReport(json: Data(json.utf8)))
    #expect(CrashIssue.body(for: report).contains("\n100 Oxbow  + 1"))
  }

  @Test func stillProducesALinkWhenNothingFits() throws {
    let url = CrashIssue.url(for: try fixture(), maximumLength: 10)
    #expect(query(url)["title"] != nil)
  }
}
