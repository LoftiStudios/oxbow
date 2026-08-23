# Task Queue Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build Oxbow's task queue — the subsystem that turns user intents into ordered CLI invocations, drives them as subprocesses, reports progress, and survives a crash.

**Architecture:** A Swift package (`OxbowKit`) with no UI and no Xcode project. An `actor QueueEngine` owns mutable state; the admission decision is a pure function over value types, so every scheduling rule is a table-driven unit test with zero subprocesses. Each CLI invocation runs in its own process group via `posix_spawn` so cancellation reaches the FFmpeg it spawns. Queue state persists as JSON; nothing resumes.

**Tech Stack:** Swift 6.2, strict concurrency (`.v6` language mode), Swift Testing (`@Test`/`#expect`), SwiftPM. **No third-party dependencies.**

**Spec:** `docs/superpowers/specs/2026-08-23-task-queue-design.md` — read it first. This plan argues from it and cites it by section.

## Global Constraints

- **Swift 6.2**, `swiftLanguageMode(.v6)` on every target. All model types are `Sendable`.
- **macOS 15** deployment target (`.macOS(.v15)`). Must match `MIN_MACOS` in `scripts/build-ffmpeg.sh`.
- **Swift Testing**, not XCTest. `import Testing`, `@Test`, `#expect`. Bundled with the toolchain — no dependency.
- **No third-party packages.** Not for JSON, not for regex, not for testing.
- **Airbnb Swift style** (`.claude/skills/swift/SKILL.md`): `UpperCamelCase` types, `lowerCamelCase` everything else, booleans read as `isX`/`hasX`, acronyms all-caps except when leading a lowerCamelCase name, event handlers named past-tense (`didFinish`, not `handleFinish`).
- **One type per file.** Do not put several structs or enums in one Swift file.
- **CLI invariants that tests must enforce** (spec §1.6, §1.7, `docs/ffmpeg.md` §3):
  - `--banner=false` must come **after** the verb.
  - Any option whose value begins with `-` must use `--opt=value`, never `--opt value`.
  - `--ffmpeg-path` is always passed explicitly.
  - Render `--output-args` must contain `h264_videotoolbox` and must never contain `libx264`.
- **Never use `Date()`, `UUID()`, or `Task.sleep` inside pure functions.** Inject them.

## File Structure

```
Package.swift
Sources/OxbowKit/
  Parsing/     ParsedLine.swift  LogLevel.swift  StepProgress.swift  StatusLineParser.swift
  Model/       JobID.swift  StepID.swift  Job.swift  Step.swift  StepStatus.swift
               StepFailure.swift  StepOutcome.swift  ResourceClass.swift
               StepKind.swift  Requests.swift  JobTemplate.swift
  Scheduling/  Scheduler.swift
  Arguments/   ArgumentBuilder.swift
  Process/     Spawn.swift  Launch.swift  HelperProcess.swift
  Persistence/ QueueStore.swift  Reconciler.swift
  Engine/      QueueEngine.swift
Tests/OxbowKitTests/
  Fixtures/cli-output/…   (moved from Tests/Fixtures/cli-output/ in Task 1)
  StatusLineParserTests.swift  SchedulerTests.swift  ArgumentBuilderTests.swift
  SpawnTests.swift  HelperProcessTests.swift  QueueStoreTests.swift
  ReconcilerTests.swift  QueueEngineTests.swift
  Support/FixtureLoader.swift  Support/JobBuilders.swift
```

Responsibilities: `Parsing/` is the **only** code that knows the CLI's text protocol (spec §4). `Scheduling/Scheduler.swift` is pure — no I/O, no clock, no actor. `Process/Spawn.swift` is the only file with C interop. `Engine/QueueEngine.swift` is the only actor and the only place side effects are performed.

---

## Task 1: Package scaffold and line splitting

The parser is first because its fixtures already exist (spec §7), and line splitting is the single behaviour most likely to be implemented wrongly (spec §1.1).

**Files:**
- Create: `Package.swift`
- Create: `Sources/OxbowKit/Parsing/StatusLineParser.swift`
- Create: `Sources/OxbowKit/Parsing/ParsedLine.swift`
- Create: `Sources/OxbowKit/Parsing/LogLevel.swift`
- Create: `Sources/OxbowKit/Parsing/StepProgress.swift`
- Move: `Tests/Fixtures/cli-output/` → `Tests/OxbowKitTests/Fixtures/cli-output/`
- Test: `Tests/OxbowKitTests/StatusLineParserTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces: `StatusLineParser.consume(_:) -> [ParsedLine]`, `ParsedLine`, `LogLevel`, `StepProgress`.

- [ ] **Step 1: Move the fixtures into the test target**

SwiftPM resources must live inside the target directory.

```bash
cd /Users/barclayloftus/Development/oxbow
mkdir -p Tests/OxbowKitTests/Fixtures
git mv Tests/Fixtures/cli-output Tests/OxbowKitTests/Fixtures/cli-output
rmdir Tests/Fixtures 2>/dev/null || true
ls Tests/OxbowKitTests/Fixtures/cli-output/
```

- [ ] **Step 2: Create `Package.swift`**

```swift
// swift-tools-version: 6.2
import PackageDescription

let package = Package(
  name: "OxbowKit",
  platforms: [.macOS(.v15)],
  products: [
    .library(name: "OxbowKit", targets: ["OxbowKit"]),
  ],
  targets: [
    .target(
      name: "OxbowKit",
      swiftSettings: [.swiftLanguageMode(.v6)]),
    .testTarget(
      name: "OxbowKitTests",
      dependencies: ["OxbowKit"],
      resources: [.copy("Fixtures")],
      swiftSettings: [.swiftLanguageMode(.v6)]),
  ])
```

- [ ] **Step 3: Create the value types the parser produces**

`Sources/OxbowKit/Parsing/LogLevel.swift`:

```swift
/// The CLI's log preambles, minus `[STATUS]` (which becomes `.status`) and
/// `<FFMPEG> ` (which has no ` - ` separator and becomes `.ffmpeg`).
public enum LogLevel: Sendable, Equatable {
  case verbose, info, warning, error
}
```

`Sources/OxbowKit/Parsing/StepProgress.swift`:

```swift
/// Everything the UI needs to draw one row.
///
/// Every field is optional because the CLI emits four different status shapes
/// and not all of them carry every field. See the design spec, section 1.2.
public struct StepProgress: Codable, Sendable, Equatable {
  public var phase: String?
  public var fraction: Double?
  public var index: Int?
  public var total: Int?
  public var elapsed: Duration?
  public var remaining: Duration?

  public init(
    phase: String? = nil,
    fraction: Double? = nil,
    index: Int? = nil,
    total: Int? = nil,
    elapsed: Duration? = nil,
    remaining: Duration? = nil)
  {
    self.phase = phase
    self.fraction = fraction
    self.index = index
    self.total = total
    self.elapsed = elapsed
    self.remaining = remaining
  }
}
```

`Sources/OxbowKit/Parsing/ParsedLine.swift`:

```swift
/// One line recovered from the helper's output.
///
/// Nothing outside `StatusLineParser` touches the CLI's raw text. If upstream
/// ever ships `--progress-format json`, this stays and the parser changes.
public enum ParsedLine: Sendable, Equatable {
  case status(StepProgress)
  case log(level: LogLevel, message: String)
  case ffmpeg(String)
}
```

- [ ] **Step 4: Write the failing test**

`Tests/OxbowKitTests/StatusLineParserTests.swift`:

```swift
import Testing
@testable import OxbowKit

@Suite("StatusLineParser line splitting")
struct StatusLineParserSplittingTests {

  /// The CLI writes progress with `\r`, never `\n`, and does not check whether
  /// stdout is a terminal. A `\n`-only splitter sees one line here, not three.
  @Test func splitsOnCarriageReturn() {
    var parser = StatusLineParser()
    let input = "[INFO] - one\r[INFO] - two\r[INFO] - three\n"

    let lines = parser.consume(Array(input.utf8))

    #expect(lines == [
      .log(level: .info, message: "one"),
      .log(level: .info, message: "two"),
      .log(level: .info, message: "three"),
    ])
  }

  /// `\r\n` together must not produce a phantom empty line.
  @Test func treatsCarriageReturnNewlinePairAsOneBreak() {
    var parser = StatusLineParser()
    let lines = parser.consume(Array("[INFO] - one\r\n[INFO] - two\n".utf8))
    #expect(lines.count == 2)
  }

  /// The CLI pads short lines with spaces to overwrite longer previous ones.
  @Test func stripsOverwritePadding() {
    var parser = StatusLineParser()
    let lines = parser.consume(Array("[INFO] - padded     \r".utf8))
    #expect(lines == [.log(level: .info, message: "padded")])
  }

  /// A line split across two reads must emit exactly once, when it completes.
  @Test func buffersAcrossChunkBoundaries() {
    var parser = StatusLineParser()
    #expect(parser.consume(Array("[INFO] - hal".utf8)).isEmpty)
    #expect(parser.consume(Array("f\n".utf8)) == [.log(level: .info, message: "half")])
  }
}
```

- [ ] **Step 5: Run the test and verify it fails**

Run: `swift test --filter StatusLineParserSplittingTests`
Expected: FAIL — `cannot find 'StatusLineParser' in scope`.

- [ ] **Step 6: Implement the parser**

`Sources/OxbowKit/Parsing/StatusLineParser.swift`:

```swift
/// Incrementally recovers lines from the helper's output stream.
///
/// This is the ONLY type that knows the CLI's text protocol.
///
/// The CLI delimits progress updates with `\r` and does not check whether
/// stdout is a terminal, so a real chat render emits 401 updates inside four
/// `\n`-delimited lines. Splitting on `\n` alone produces a frozen progress
/// bar that jumps to 100% at the end. See the design spec, section 1.1.
public struct StatusLineParser: Sendable {
  private var buffer: [UInt8] = []

  public init() {}

  /// Feed bytes as they arrive. Returns whatever complete lines they finished.
  /// An incomplete trailing line is retained until a later call completes it.
  public mutating func consume(_ bytes: some Sequence<UInt8>) -> [ParsedLine] {
    var lines: [ParsedLine] = []
    for byte in bytes {
      if byte == UInt8(ascii: "\n") || byte == UInt8(ascii: "\r") {
        if let line = flush() { lines.append(line) }
      } else {
        buffer.append(byte)
      }
    }
    return lines
  }

  /// Emit anything still buffered. Call when the process has exited, because
  /// the CLI does not always terminate its final line.
  public mutating func finish() -> ParsedLine? {
    flush()
  }

  private mutating func flush() -> ParsedLine? {
    defer { buffer.removeAll(keepingCapacity: true) }

    // A `\r\n` pair flushes twice; the second flush is empty and is not a line.
    guard !buffer.isEmpty else { return nil }

    // Trailing spaces are the CLI overwriting a longer previous line.
    let text = String(decoding: buffer, as: UTF8.self)
      .trimmingCharacters(in: .whitespaces)
    guard !text.isEmpty else { return nil }

    return Self.classify(text)
  }

  static func classify(_ text: String) -> ParsedLine {
    // Placeholder until Task 2. Keeps Task 1's tests honest and compiling.
    if let rest = text.strippingPrefix("[INFO] - ") {
      return .log(level: .info, message: rest)
    }
    return .log(level: .info, message: text)
  }
}

extension String {
  /// Returns the remainder after `prefix`, or nil if the prefix is absent.
  func strippingPrefix(_ prefix: String) -> String? {
    hasPrefix(prefix) ? String(dropFirst(prefix.count)) : nil
  }
}
```

- [ ] **Step 7: Run the tests and verify they pass**

Run: `swift test --filter StatusLineParserSplittingTests`
Expected: PASS, 4 tests.

- [ ] **Step 8: Commit**

```bash
git add Package.swift Sources/OxbowKit/Parsing Tests/OxbowKitTests
git commit -m "feat(parsing): add OxbowKit package and CR/LF line splitting

The CLI delimits progress with carriage returns and does not check whether
stdout is a terminal, so a newline-only reader sees a frozen progress bar.
Splitting handles \\r, \\n, and \\r\\n pairs, and strips the overwrite padding
the CLI writes to blank longer previous lines."
```

---

## Task 2: Preamble classification

**Files:**
- Modify: `Sources/OxbowKit/Parsing/StatusLineParser.swift` (replace `classify`)
- Test: `Tests/OxbowKitTests/StatusLineParserTests.swift` (add a suite)

**Interfaces:**
- Consumes: `ParsedLine`, `LogLevel`, `StatusLineParser` from Task 1.
- Produces: `StatusLineParser.classify(_:)` handling all six preambles.

- [ ] **Step 1: Write the failing test**

Append to `Tests/OxbowKitTests/StatusLineParserTests.swift`:

```swift
@Suite("StatusLineParser preambles")
struct StatusLineParserPreambleTests {

  @Test(arguments: [
    ("[VERBOSE] - v", LogLevel.verbose, "v"),
    ("[INFO] - i", LogLevel.info, "i"),
    ("[WARNING] - w", LogLevel.warning, "w"),
    ("[ERROR] - e", LogLevel.error, "e"),
  ])
  func classifiesLogPreambles(input: String, level: LogLevel, message: String) {
    #expect(StatusLineParser.classify(input) == .log(level: level, message: message))
  }

  /// `<FFMPEG> ` is the one preamble with no ` - ` separator.
  @Test func classifiesFfmpegPreambleWhichHasNoSeparator() {
    #expect(StatusLineParser.classify("<FFMPEG> frame= 60") == .ffmpeg("frame= 60"))
  }

  @Test func classifiesStatusPreamble() {
    guard case .status = StatusLineParser.classify("[STATUS] - Downloading 50%") else {
      Issue.record("expected .status")
      return
    }
  }

  /// Unrecognised output must never be dropped — it is often the useful part.
  @Test func treatsUnrecognisedTextAsInfo() {
    #expect(StatusLineParser.classify("bare text") == .log(level: .info, message: "bare text"))
  }
}
```

- [ ] **Step 2: Run the test and verify it fails**

Run: `swift test --filter StatusLineParserPreambleTests`
Expected: FAIL — `[VERBOSE] - v` classifies as `.log(level: .info, ...)`.

- [ ] **Step 3: Replace `classify`**

In `Sources/OxbowKit/Parsing/StatusLineParser.swift`, replace the whole `classify` method:

```swift
  /// The CLI's six output preambles, verified against version 1.56.5.
  static func classify(_ text: String) -> ParsedLine {
    if let rest = text.strippingPrefix("[STATUS] - ") {
      return .status(parseProgress(rest))
    }
    if let rest = text.strippingPrefix("[VERBOSE] - ") {
      return .log(level: .verbose, message: rest)
    }
    if let rest = text.strippingPrefix("[INFO] - ") {
      return .log(level: .info, message: rest)
    }
    if let rest = text.strippingPrefix("[WARNING] - ") {
      return .log(level: .warning, message: rest)
    }
    if let rest = text.strippingPrefix("[ERROR] - ") {
      return .log(level: .error, message: rest)
    }
    // Note: no ` - ` separator on this one.
    if let rest = text.strippingPrefix("<FFMPEG> ") {
      return .ffmpeg(rest)
    }
    // Never drop unrecognised output; it is frequently the useful part.
    return .log(level: .info, message: text)
  }

  /// Filled in by Task 3.
  static func parseProgress(_ text: String) -> StepProgress {
    StepProgress(phase: text)
  }
```

- [ ] **Step 4: Run all parser tests and verify they pass**

Run: `swift test --filter StatusLineParser`
Expected: PASS, 11 tests.

- [ ] **Step 5: Commit**

```bash
git add Sources/OxbowKit/Parsing/StatusLineParser.swift Tests/OxbowKitTests/StatusLineParserTests.swift
git commit -m "feat(parsing): classify the CLI's six output preambles

STATUS, VERBOSE, INFO, WARNING, ERROR, and <FFMPEG> — the last having no
' - ' separator. Unrecognised lines become .info rather than being dropped."
```

---

## Task 3: The four status shapes

**Files:**
- Modify: `Sources/OxbowKit/Parsing/StatusLineParser.swift` (replace `parseProgress`)
- Test: `Tests/OxbowKitTests/StatusLineParserTests.swift` (add a suite)

**Interfaces:**
- Consumes: `StepProgress`, `StatusLineParser.classify(_:)` from Tasks 1–2.
- Produces: `StatusLineParser.parseProgress(_:) -> StepProgress` handling all four observed shapes.

All four shapes below were observed in real output (spec §1.2). Parse from the
right: strip the trailing counter or times group, then the percentage, and
whatever remains is the phase.

- [ ] **Step 1: Write the failing test**

Append to `Tests/OxbowKitTests/StatusLineParserTests.swift`:

```swift
@Suite("StatusLineParser status shapes")
struct StatusLineParserStatusTests {

  /// Shape 1: phase plus step counter, no percentage.
  @Test func parsesPhaseAndCounter() {
    let p = StatusLineParser.parseProgress("Fetching Video Info [1/4]")
    #expect(p.phase == "Fetching Video Info")
    #expect(p.fraction == nil)
    #expect(p.index == 1)
    #expect(p.total == 4)
  }

  /// Shape 2: phase, percentage, and counter.
  @Test func parsesPhasePercentAndCounter() {
    let p = StatusLineParser.parseProgress("Downloading 100% [2/4]")
    #expect(p.phase == "Downloading")
    #expect(p.fraction == 1.0)
    #expect(p.index == 2)
    #expect(p.total == 4)
  }

  /// Shape 3: phase and percentage, no counter. Emitted by `chatdownload`.
  @Test func parsesPhaseAndPercentWithoutCounter() {
    let p = StatusLineParser.parseProgress("Downloading 25%")
    #expect(p.phase == "Downloading")
    #expect(p.fraction == 0.25)
    #expect(p.index == nil)
    #expect(p.total == nil)
  }

  /// Shape 4: phase, percentage, elapsed and remaining. Emitted by `chatrender`.
  @Test func parsesPhasePercentAndTimes() {
    let p = StatusLineParser.parseProgress("Rendering Video 45% (0h1m5s Elapsed | 2h0m3s Remaining)")
    #expect(p.phase == "Rendering Video")
    #expect(p.fraction == 0.45)
    #expect(p.elapsed == .seconds(65))
    #expect(p.remaining == .seconds(7203))
  }

  /// A phase containing a digit must not be mistaken for a percentage.
  @Test func doesNotMistakeDigitsInPhaseForPercent() {
    let p = StatusLineParser.parseProgress("Combining Parts 2 [3/5]")
    #expect(p.phase == "Combining Parts 2")
    #expect(p.fraction == nil)
  }
}
```

- [ ] **Step 2: Run the test and verify it fails**

Run: `swift test --filter StatusLineParserStatusTests`
Expected: FAIL — `phase` is the whole string, `fraction` is nil.

- [ ] **Step 3: Replace `parseProgress`**

Add `import Foundation` at the top of `StatusLineParser.swift` if not already
present, then replace the placeholder `parseProgress`:

```swift
  /// Parses the four status shapes the CLI emits. See the design spec, §1.2.
  ///
  /// Parsed right-to-left: the trailing counter or times group is stripped
  /// first, then the percentage, and the remainder is the phase. Doing it in
  /// this order is what stops a digit inside a phase name being read as a
  /// percentage.
  static func parseProgress(_ text: String) -> StepProgress {
    var remainder = Substring(text)
    var progress = StepProgress()

    if let match = remainder.firstMatch(of: /\s*\[(\d+)\/(\d+)\]$/) {
      progress.index = Int(match.1)
      progress.total = Int(match.2)
      remainder = remainder[..<match.range.lowerBound]
    }

    let times = /\s*\((\d+)h(\d+)m(\d+)s Elapsed \| (\d+)h(\d+)m(\d+)s Remaining\)$/
    if let match = remainder.firstMatch(of: times) {
      progress.elapsed = Self.duration(match.1, match.2, match.3)
      progress.remaining = Self.duration(match.4, match.5, match.6)
      remainder = remainder[..<match.range.lowerBound]
    }

    if let match = remainder.firstMatch(of: /\s+(\d+)%$/) {
      if let percent = Int(match.1) {
        progress.fraction = Double(percent) / 100
      }
      remainder = remainder[..<match.range.lowerBound]
    }

    let phase = remainder.trimmingCharacters(in: .whitespaces)
    progress.phase = phase.isEmpty ? nil : phase
    return progress
  }

  private static func duration(
    _ hours: Substring,
    _ minutes: Substring,
    _ seconds: Substring)
    -> Duration
  {
    let h = Int(hours) ?? 0
    let m = Int(minutes) ?? 0
    let s = Int(seconds) ?? 0
    return .seconds(h * 3600 + m * 60 + s)
  }
```

- [ ] **Step 4: Run all parser tests and verify they pass**

Run: `swift test --filter StatusLineParser`
Expected: PASS, 16 tests.

- [ ] **Step 5: Commit**

```bash
git add Sources/OxbowKit/Parsing/StatusLineParser.swift Tests/OxbowKitTests/StatusLineParserTests.swift
git commit -m "feat(parsing): parse all four observed status line shapes

Parsed right-to-left so a digit inside a phase name is never mistaken for a
percentage. Covers phase+counter, phase+percent+counter, phase+percent, and
phase+percent+elapsed/remaining."
```

---

## Task 4: Replay against real captured output

The fixtures are real bytes from real runs (`Tests/OxbowKitTests/Fixtures/cli-output/README.md`). This task proves the parser survives arbitrary chunk boundaries, which is how bytes actually arrive from a pipe.

**Files:**
- Create: `Tests/OxbowKitTests/Support/FixtureLoader.swift`
- Test: `Tests/OxbowKitTests/StatusLineParserFixtureTests.swift`

**Interfaces:**
- Consumes: `StatusLineParser`, `ParsedLine` from Tasks 1–3.
- Produces: `Fixture.bytes(_:) throws -> [UInt8]` for later tasks.

- [ ] **Step 1: Write the fixture loader**

`Tests/OxbowKitTests/Support/FixtureLoader.swift`:

```swift
import Foundation

enum Fixture {
  /// Loads a captured CLI output fixture as raw bytes.
  ///
  /// Raw bytes, not `String`, because the `\r` placement is the entire point
  /// and must not pass through any newline-normalising API.
  static func bytes(_ name: String) throws -> [UInt8] {
    let url = try #require(Bundle.module.url(
      forResource: name,
      withExtension: nil,
      subdirectory: "Fixtures/cli-output"))
    return try [UInt8](Data(contentsOf: url))
  }
}
```

Note: `#require` needs `import Testing` in this file too. Add both imports.

- [ ] **Step 2: Write the failing test**

`Tests/OxbowKitTests/StatusLineParserFixtureTests.swift`:

```swift
import Foundation
import Testing
@testable import OxbowKit

@Suite("StatusLineParser against captured CLI output")
struct StatusLineParserFixtureTests {

  /// The headline case: 401 progress updates arrive inside FOUR newline-
  /// delimited lines. A `\n`-splitting parser reports 4, not 401.
  @Test func recoversAllUpdatesFromChatRender() throws {
    var parser = StatusLineParser()
    let lines = parser.consume(try Fixture.bytes("chatrender-success.stdout"))

    let statuses = lines.compactMap { line -> StepProgress? in
      if case .status(let p) = line { return p }
      return nil
    }

    #expect(statuses.count > 300, "expected hundreds of updates, got \(statuses.count)")
    #expect(statuses.last?.fraction == 1.0)
    #expect(statuses.contains { $0.phase == "Rendering Video" })
  }

  /// Chunk boundaries must not change the result. Byte-at-a-time is the
  /// cruellest case and the one a pipe can genuinely produce.
  @Test(arguments: [1, 7, 64, 4096])
  func producesIdenticalOutputAtAnyChunkSize(chunkSize: Int) throws {
    let bytes = try Fixture.bytes("chatrender-success.stdout")

    var whole = StatusLineParser()
    let expected = whole.consume(bytes)

    var chunked = StatusLineParser()
    var actual: [ParsedLine] = []
    for start in stride(from: 0, to: bytes.count, by: chunkSize) {
      let end = min(start + chunkSize, bytes.count)
      actual += chunked.consume(bytes[start..<end])
    }
    if let tail = chunked.finish() { actual.append(tail) }

    #expect(actual == expected)
  }

  @Test func recoversVideoDownloadPhases() throws {
    var parser = StatusLineParser()
    let lines = parser.consume(try Fixture.bytes("videodownload-success.stdout"))

    let phases = lines.compactMap { line -> String? in
      if case .status(let p) = line { return p.phase }
      return nil
    }

    #expect(phases.contains("Fetching Video Info"))
    #expect(phases.contains("Downloading"))
    #expect(phases.contains("Verifying Parts"))
    #expect(phases.contains("Finalizing Video"))
  }

  /// `chatdownload` emits the no-counter shape.
  @Test func recoversChatDownloadWithoutCounters() throws {
    var parser = StatusLineParser()
    let lines = parser.consume(try Fixture.bytes("chatdownload-success.stdout"))

    let statuses = lines.compactMap { line -> StepProgress? in
      if case .status(let p) = line { return p }
      return nil
    }

    #expect(statuses.allSatisfy { $0.index == nil })
    #expect(statuses.contains { $0.phase == "Backfilling Commenter Info" })
  }
}
```

- [ ] **Step 3: Run the test and verify it fails**

Run: `swift test --filter StatusLineParserFixtureTests`
Expected: FAIL — `Fixture` not found until Step 1's file compiles; then PASS if Tasks 1–3 are correct. If `recoversAllUpdatesFromChatRender` reports 4 instead of 401, the `\r` handling regressed.

- [ ] **Step 4: Run the tests and verify they pass**

Run: `swift test --filter StatusLineParser`
Expected: PASS, 23 tests.

- [ ] **Step 5: Commit**

```bash
git add Tests/OxbowKitTests
git commit -m "test(parsing): replay real captured CLI output at varying chunk sizes

chatrender-success.stdout carries 401 progress updates inside four newline-
delimited lines. Replaying at 1, 7, 64 and 4096 byte chunks proves the
incremental parser is unaffected by where a read boundary lands."
```

---

## Task 5: Domain model

Pure data. No logic beyond derived properties, which exist precisely so that nothing is stored twice and able to drift (spec §2).

**Files:**
- Create: `Sources/OxbowKit/Model/JobID.swift`, `StepID.swift`, `Job.swift`, `Step.swift`,
  `StepStatus.swift`, `JobStatus.swift`, `StepFailure.swift`, `StepOutcome.swift`,
  `ResourceClass.swift`, `StepKind.swift`, `Requests.swift`
- Test: `Tests/OxbowKitTests/ModelTests.swift`

**Interfaces:**
- Consumes: `StepProgress` from Task 1.
- Produces: `Job`, `Step`, `StepID`, `JobID`, `StepStatus`, `JobStatus`, `StepKind`,
  `StepFailure`, `StepOutcome`, `ResourceClass`, `VideoRequest`, `ClipRequest`,
  `ChatRequest`, `RenderRequest`, `Job.status`, `StepKind.resource`.

- [ ] **Step 1: Write the failing test**

`Tests/OxbowKitTests/ModelTests.swift`:

```swift
import Foundation
import Testing
@testable import OxbowKit

@Suite("Domain model")
struct ModelTests {

  private func step(_ status: StepStatus) -> Step {
    Step(
      id: StepID(rawValue: UUID()),
      kind: .downloadChat(ChatRequest(videoID: "1", format: .json)),
      status: status,
      progress: StepProgress(),
      dependsOn: nil,
      artifact: nil)
  }

  private func job(_ statuses: [StepStatus]) -> Job {
    Job(
      id: JobID(rawValue: UUID()),
      created: Date(timeIntervalSince1970: 0),
      title: "t",
      steps: statuses.map(step))
  }

  @Test func downloadsAreNetworkAndRendersAreCompute() {
    #expect(StepKind.downloadVideo(VideoRequest(
      videoID: "1", quality: "160p30", destination: URL(filePath: "/tmp/a"))).resource == .network)
    #expect(StepKind.downloadClip(ClipRequest(
      clipSlug: "s", quality: "480p", destination: URL(filePath: "/tmp/a"))).resource == .network)
    #expect(StepKind.downloadChat(ChatRequest(videoID: "1", format: .json)).resource == .network)
    #expect(StepKind.renderChat(RenderRequest(destination: URL(filePath: "/tmp/a"))).resource == .compute)
  }

  @Test func jobStatusIsRunningWheneverAnyStepRuns() {
    #expect(job([.done, .running, .queued]).status == .running)
  }

  @Test func jobStatusIsDoneOnlyWhenEveryStepIsDone() {
    #expect(job([.done, .done]).status == .done)
    #expect(job([.done, .queued]).status == .queued)
  }

  /// A blocked step means something upstream failed, so the job reads failed.
  @Test func jobStatusIsFailedWhenAnyStepFailedOrIsBlocked() {
    #expect(job([.done, .failed(StepFailure(kind: .noArtifact, summary: "x"))]).status == .failed)
    #expect(job([.done, .blocked]).status == .failed)
  }

  @Test func jobStatusIsCancelledWhenAStepWasCancelledAndNoneFailed() {
    #expect(job([.done, .cancelled]).status == .cancelled)
  }

  /// Everything persisted must survive a round trip; the queue file depends on it.
  @Test func jobRoundTripsThroughCodable() throws {
    let original = job([.queued, .done, .failed(StepFailure(kind: .exited(code: 134), summary: "boom"))])
    let data = try JSONEncoder().encode(original)
    let decoded = try JSONDecoder().decode(Job.self, from: data)
    #expect(decoded == original)
  }
}
```

- [ ] **Step 2: Run the test and verify it fails**

Run: `swift test --filter ModelTests`
Expected: FAIL — none of these types exist.

- [ ] **Step 3: Create the identifier types**

`Sources/OxbowKit/Model/JobID.swift`:

```swift
import Foundation

public struct JobID: Hashable, Codable, Sendable {
  public let rawValue: UUID
  public init(rawValue: UUID) { self.rawValue = rawValue }
}
```

`Sources/OxbowKit/Model/StepID.swift`:

```swift
import Foundation

public struct StepID: Hashable, Codable, Sendable {
  public let rawValue: UUID
  public init(rawValue: UUID) { self.rawValue = rawValue }
}
```

- [ ] **Step 4: Create the request types**

`Sources/OxbowKit/Model/Requests.swift` (the one deliberate exception to
one-type-per-file: these four are a single cohesive group consumed only by the
argument builder):

```swift
import Foundation

public enum ChatFormat: String, Codable, Sendable, Equatable {
  case json, text, html
}

public struct VideoRequest: Codable, Sendable, Equatable {
  public var videoID: String
  public var quality: String
  public var trimStart: Duration?
  public var trimEnd: Duration?
  public var destination: URL

  public init(
    videoID: String,
    quality: String,
    trimStart: Duration? = nil,
    trimEnd: Duration? = nil,
    destination: URL)
  {
    self.videoID = videoID
    self.quality = quality
    self.trimStart = trimStart
    self.trimEnd = trimEnd
    self.destination = destination
  }
}

public struct ClipRequest: Codable, Sendable, Equatable {
  public var clipSlug: String
  public var quality: String
  public var destination: URL

  public init(clipSlug: String, quality: String, destination: URL) {
    self.clipSlug = clipSlug
    self.quality = quality
    self.destination = destination
  }
}

public struct ChatRequest: Codable, Sendable, Equatable {
  public var videoID: String
  public var trimStart: Duration?
  public var trimEnd: Duration?
  public var format: ChatFormat
  public var isEmbeddingImages: Bool
  /// `nil` means the user does not want to keep the chat file, so it stays in
  /// the job workspace and is discarded with it. This is the queue half of the
  /// open question in the design spec, §10.
  public var destination: URL?

  public init(
    videoID: String,
    trimStart: Duration? = nil,
    trimEnd: Duration? = nil,
    format: ChatFormat,
    isEmbeddingImages: Bool = false,
    destination: URL? = nil)
  {
    self.videoID = videoID
    self.trimStart = trimStart
    self.trimEnd = trimEnd
    self.format = format
    self.isEmbeddingImages = isEmbeddingImages
    self.destination = destination
  }
}

public struct RenderRequest: Codable, Sendable, Equatable {
  public var width: Int
  public var height: Int
  public var framerate: Int
  public var fontSize: Double
  /// VideoToolbox is bitrate-targeted; there is no CRF equivalent.
  /// See docs/ffmpeg.md, section 3.
  public var bitrateMbps: Int
  public var isSharpened: Bool
  public var destination: URL

  public init(
    width: Int = 350,
    height: Int = 600,
    framerate: Int = 30,
    fontSize: Double = 12,
    bitrateMbps: Int = 3,
    isSharpened: Bool = false,
    destination: URL)
  {
    self.width = width
    self.height = height
    self.framerate = framerate
    self.fontSize = fontSize
    self.bitrateMbps = bitrateMbps
    self.isSharpened = isSharpened
    self.destination = destination
  }
}
```

- [ ] **Step 5: Create the step types**

`Sources/OxbowKit/Model/ResourceClass.swift`:

```swift
/// What a step contends for. The scheduler admits at most one running step per
/// class, which is what lets a download and a render overlap.
public enum ResourceClass: Sendable, Equatable, CaseIterable {
  case network
  case compute
}
```

`Sources/OxbowKit/Model/StepKind.swift`:

```swift
public enum StepKind: Codable, Sendable, Equatable {
  case downloadVideo(VideoRequest)
  case downloadClip(ClipRequest)
  case downloadChat(ChatRequest)
  case renderChat(RenderRequest)

  /// Derived, never stored — a stored copy could drift from the kind.
  public var resource: ResourceClass {
    switch self {
    case .downloadVideo, .downloadClip, .downloadChat: .network
    case .renderChat: .compute
    }
  }
}
```

`Sources/OxbowKit/Model/StepFailure.swift`:

```swift
public struct StepFailure: Codable, Sendable, Equatable {
  public enum Kind: Codable, Sendable, Equatable {
    /// The app died while this step was running.
    case interrupted
    case launchFailed(String)
    case exited(code: Int32)
    /// Killed by a signal we did not send — i.e. it crashed.
    case signalled(Int32)
    /// Exited without producing a usable artifact. This, not the exit code, is
    /// the real failure criterion. See the design spec, §1.5.
    case noArtifact
    case moveFailed(String)
  }

  public var kind: Kind
  /// One sentence, shown in the row. Never a stack trace.
  public var summary: String
  /// Full stderr, behind a disclosure, copyable for bug reports.
  public var detail: String?

  public init(kind: Kind, summary: String, detail: String? = nil) {
    self.kind = kind
    self.summary = summary
    self.detail = detail
  }
}
```

`Sources/OxbowKit/Model/StepStatus.swift`:

```swift
public enum StepStatus: Codable, Sendable, Equatable {
  case queued
  /// An upstream step failed or was cancelled, so this one cannot start.
  case blocked
  case running
  case done
  case failed(StepFailure)
  case cancelled
}
```

`Sources/OxbowKit/Model/StepOutcome.swift`:

```swift
import Foundation

/// What a finished step reports back to the scheduler.
public enum StepOutcome: Sendable, Equatable {
  case succeeded(artifact: URL)
  case failed(StepFailure)
  case cancelled
}
```

`Sources/OxbowKit/Model/Step.swift`:

```swift
import Foundation

public struct Step: Identifiable, Codable, Sendable, Equatable {
  public let id: StepID
  public let kind: StepKind
  public var status: StepStatus
  public var progress: StepProgress
  /// The step whose artifact this one consumes.
  ///
  /// Always earlier in `Job.steps`, but named explicitly rather than assumed to
  /// be the immediate predecessor: in video+chat+render the render depends on
  /// step 2, not step 1. At most one parent, so this is a forest and never
  /// needs a topological sort.
  public let dependsOn: StepID?
  public var artifact: URL?

  public init(
    id: StepID,
    kind: StepKind,
    status: StepStatus = .queued,
    progress: StepProgress = StepProgress(),
    dependsOn: StepID? = nil,
    artifact: URL? = nil)
  {
    self.id = id
    self.kind = kind
    self.status = status
    self.progress = progress
    self.dependsOn = dependsOn
    self.artifact = artifact
  }
}
```

- [ ] **Step 6: Create `Job` and its derived status**

`Sources/OxbowKit/Model/JobStatus.swift`:

```swift
public enum JobStatus: Sendable, Equatable {
  case queued, running, done, failed, cancelled
}
```

`Sources/OxbowKit/Model/Job.swift`:

```swift
import Foundation

public struct Job: Identifiable, Codable, Sendable, Equatable {
  public let id: JobID
  public let created: Date
  public var title: String
  /// Ordered. Index order is execution order.
  public var steps: [Step]

  public init(id: JobID, created: Date, title: String, steps: [Step]) {
    self.id = id
    self.created = created
    self.title = title
    self.steps = steps
  }

  /// Derived, never stored. A stored summary can drift from the steps it
  /// summarises, and drift is what makes a queue feel haunted.
  ///
  /// Precedence is deliberate: running beats failed beats cancelled, so a job
  /// still doing work never reads as finished.
  public var status: JobStatus {
    if steps.contains(where: { $0.status == .running }) { return .running }
    if steps.contains(where: {
      if case .failed = $0.status { return true }
      return $0.status == .blocked
    }) { return .failed }
    if steps.contains(where: { $0.status == .cancelled }) { return .cancelled }
    if steps.allSatisfy({ $0.status == .done }) { return .done }
    return .queued
  }
}
```

- [ ] **Step 7: Run the tests and verify they pass**

Run: `swift test --filter ModelTests`
Expected: PASS, 6 tests.

If `jobRoundTripsThroughCodable` fails on `Duration`, replace the `Duration?`
properties with `Double?` seconds and convert at the boundary — do not add a
dependency.

- [ ] **Step 8: Commit**

```bash
git add Sources/OxbowKit/Model Tests/OxbowKitTests/ModelTests.swift
git commit -m "feat(model): add Job, Step, and the request value types

Job status and resource class are derived rather than stored, so there is one
source of truth. dependsOn is explicit rather than assumed to be the previous
step, because in video+chat+render the render depends on step 2, not step 1."
```

---

## Task 6: Job templates

The five v1 shapes (spec §2). Templates are a construction-time concern — once expanded, the runtime model is uniform.

**Files:**
- Create: `Sources/OxbowKit/Model/JobTemplate.swift`
- Test: `Tests/OxbowKitTests/JobTemplateTests.swift`

**Interfaces:**
- Consumes: everything from Task 5.
- Produces: `JobTemplate`, `JobTemplate.makeJob(id:title:created:nextStepID:) -> Job`.

- [ ] **Step 1: Write the failing test**

`Tests/OxbowKitTests/JobTemplateTests.swift`:

```swift
import Foundation
import Testing
@testable import OxbowKit

@Suite("Job templates")
struct JobTemplateTests {

  /// Deterministic ID generator so assertions can name specific steps.
  private func idGenerator() -> () -> StepID {
    var n = 0
    return {
      n += 1
      return StepID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-\(String(format: "%012d", n))")!)
    }
  }

  private func makeJob(_ template: JobTemplate) -> Job {
    template.makeJob(
      id: JobID(rawValue: UUID()),
      title: "t",
      created: Date(timeIntervalSince1970: 0),
      nextStepID: idGenerator())
  }

  private var video: VideoRequest {
    VideoRequest(videoID: "2844548319", quality: "160p30", destination: URL(filePath: "/tmp/v.mp4"))
  }
  private var chat: ChatRequest { ChatRequest(videoID: "2844548319", format: .json) }
  private var render: RenderRequest { RenderRequest(destination: URL(filePath: "/tmp/c.mp4")) }

  @Test func singleVerbTemplatesProduceOneIndependentStep() {
    let job = makeJob(.video(video))
    #expect(job.steps.count == 1)
    #expect(job.steps[0].dependsOn == nil)
  }

  @Test func chatAndRenderMakesTheRenderDependOnTheChatDownload() {
    let job = makeJob(.chatAndRender(chat, render))
    #expect(job.steps.count == 2)
    #expect(job.steps[0].dependsOn == nil)
    #expect(job.steps[1].dependsOn == job.steps[0].id)
  }

  /// The case the explicit `dependsOn` field exists for: the render depends on
  /// step 2 (the chat), NOT step 1 (the video), and the video is independent.
  @Test func videoChatAndRenderMakesTheRenderDependOnTheChatNotTheVideo() {
    let job = makeJob(.videoChatAndRender(video, chat, render))
    #expect(job.steps.count == 3)
    #expect(job.steps[0].dependsOn == nil, "video download is independent")
    #expect(job.steps[1].dependsOn == nil, "chat download is independent")
    #expect(job.steps[2].dependsOn == job.steps[1].id, "render depends on the chat")
    #expect(job.steps[2].dependsOn != job.steps[0].id)
  }

  @Test func everyNewStepStartsQueued() {
    let job = makeJob(.videoChatAndRender(video, chat, render))
    #expect(job.steps.allSatisfy { $0.status == .queued })
  }
}
```

- [ ] **Step 2: Run the test and verify it fails**

Run: `swift test --filter JobTemplateTests`
Expected: FAIL — `cannot find 'JobTemplate' in scope`.

- [ ] **Step 3: Implement the templates**

`Sources/OxbowKit/Model/JobTemplate.swift`:

```swift
import Foundation

/// A user intent, before it becomes steps.
///
/// Templates exist only at construction time. Once expanded, the runtime model
/// is uniform and nothing needs to know which template produced a job.
public enum JobTemplate: Sendable {
  case video(VideoRequest)
  case clip(ClipRequest)
  case chat(ChatRequest)
  case chatAndRender(ChatRequest, RenderRequest)
  case videoChatAndRender(VideoRequest, ChatRequest, RenderRequest)

  /// `nextStepID` is injected rather than calling `UUID()` directly so that
  /// tests can assert against specific steps.
  public func makeJob(
    id: JobID,
    title: String,
    created: Date,
    nextStepID: () -> StepID)
    -> Job
  {
    var steps: [Step] = []

    switch self {
    case .video(let request):
      steps = [Step(id: nextStepID(), kind: .downloadVideo(request))]

    case .clip(let request):
      steps = [Step(id: nextStepID(), kind: .downloadClip(request))]

    case .chat(let request):
      steps = [Step(id: nextStepID(), kind: .downloadChat(request))]

    case .chatAndRender(let chatRequest, let renderRequest):
      let chatStep = Step(id: nextStepID(), kind: .downloadChat(chatRequest))
      steps = [
        chatStep,
        Step(id: nextStepID(), kind: .renderChat(renderRequest), dependsOn: chatStep.id),
      ]

    case .videoChatAndRender(let videoRequest, let chatRequest, let renderRequest):
      let chatStep = Step(id: nextStepID(), kind: .downloadChat(chatRequest))
      steps = [
        // Independent of the chat steps: a failed video download must not
        // block the render, and vice versa.
        Step(id: nextStepID(), kind: .downloadVideo(videoRequest)),
        chatStep,
        Step(id: nextStepID(), kind: .renderChat(renderRequest), dependsOn: chatStep.id),
      ]
    }

    return Job(id: id, created: created, title: title, steps: steps)
  }
}
```

Note the ordering wrinkle in the last case: `chatStep` is constructed before the
video step so the render can reference its id, but it is placed *second* in the
array. Execution order is array order; construction order is not.

- [ ] **Step 4: Run the tests and verify they pass**

Run: `swift test --filter JobTemplateTests`
Expected: PASS, 4 tests.

If `videoChatAndRenderMakesTheRenderDependOnTheChatNotTheVideo` fails on step
ids, check that `nextStepID` is called in array order for the video step.

- [ ] **Step 5: Commit**

```bash
git add Sources/OxbowKit/Model/JobTemplate.swift Tests/OxbowKitTests/JobTemplateTests.swift
git commit -m "feat(model): add the five v1 job templates

Fixed shapes rather than a general DAG: v1 has exactly one dependency edge,
render-needs-chat. The video download in video+chat+render is deliberately
independent, so a failed video download does not block the chat render."
```

---

## Task 7: Scheduler admission

The pure function that the whole architecture exists to make testable (spec §3).

**Files:**
- Create: `Sources/OxbowKit/Scheduling/Scheduler.swift`
- Create: `Tests/OxbowKitTests/Support/JobBuilders.swift`
- Test: `Tests/OxbowKitTests/SchedulerAdmissionTests.swift`

**Interfaces:**
- Consumes: `Job`, `Step`, `StepID`, `StepStatus`, `ResourceClass` from Task 5.
- Produces: `Scheduler.admissible(jobs:running:) -> [StepID]`, and `Build` test helpers.

- [ ] **Step 1: Write the test builders**

`Tests/OxbowKitTests/Support/JobBuilders.swift`:

```swift
import Foundation
@testable import OxbowKit

/// Terse, deterministic job construction for scheduler tests.
enum Build {
  static func stepID(_ n: Int) -> StepID {
    StepID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-\(String(format: "%012d", n))")!)
  }

  static func jobID(_ n: Int) -> JobID {
    JobID(rawValue: UUID(uuidString: "00000000-0000-0000-0001-\(String(format: "%012d", n))")!)
  }

  /// A `.network` step — any of the download verbs contends the same way.
  static func network(_ n: Int, _ status: StepStatus = .queued, dependsOn: StepID? = nil) -> Step {
    Step(
      id: stepID(n),
      kind: .downloadChat(ChatRequest(videoID: "v", format: .json)),
      status: status,
      dependsOn: dependsOn)
  }

  /// A `.compute` step.
  static func compute(_ n: Int, _ status: StepStatus = .queued, dependsOn: StepID? = nil) -> Step {
    Step(
      id: stepID(n),
      kind: .renderChat(RenderRequest(destination: URL(filePath: "/tmp/o.mp4"))),
      status: status,
      dependsOn: dependsOn)
  }

  static func job(_ n: Int, createdAt seconds: TimeInterval = 0, _ steps: Step...) -> Job {
    Job(
      id: jobID(n),
      created: Date(timeIntervalSince1970: seconds),
      title: "job \(n)",
      steps: steps)
  }
}
```

- [ ] **Step 2: Write the failing test**

`Tests/OxbowKitTests/SchedulerAdmissionTests.swift`:

```swift
import Foundation
import Testing
@testable import OxbowKit

@Suite("Scheduler admission")
struct SchedulerAdmissionTests {

  @Test func admitsAQueuedStepWithNoDependency() {
    let jobs = [Build.job(1, Build.network(1))]
    #expect(Scheduler.admissible(jobs: jobs, running: []) == [Build.stepID(1)])
  }

  /// The class-aware rule: two downloads must not overlap.
  @Test func admitsOnlyOneNetworkStepAtATime() {
    let jobs = [Build.job(1, Build.network(1), Build.network(2))]
    #expect(Scheduler.admissible(jobs: jobs, running: []) == [Build.stepID(1)])
  }

  /// ...but a download and a render may, which is the whole point.
  @Test func admitsOneNetworkAndOneComputeTogether() {
    let jobs = [Build.job(1, Build.network(1), Build.compute(2))]
    let admitted = Scheduler.admissible(jobs: jobs, running: [])
    #expect(Set(admitted) == [Build.stepID(1), Build.stepID(2)])
  }

  @Test func doesNotAdmitAStepWhoseClassIsAlreadyBusy() {
    let jobs = [Build.job(1, Build.network(1, .running), Build.network(2))]
    #expect(Scheduler.admissible(jobs: jobs, running: [Build.stepID(1)]).isEmpty)
  }

  @Test func doesNotAdmitAStepWhoseDependencyIsUnfinished() {
    let jobs = [Build.job(1, Build.network(1), Build.compute(2, dependsOn: Build.stepID(1)))]
    #expect(Scheduler.admissible(jobs: jobs, running: []) == [Build.stepID(1)])
  }

  @Test func admitsAStepOnceItsDependencyIsDone() {
    let jobs = [Build.job(1, Build.network(1, .done), Build.compute(2, dependsOn: Build.stepID(1)))]
    #expect(Scheduler.admissible(jobs: jobs, running: []) == [Build.stepID(2)])
  }

  @Test(arguments: [StepStatus.running, .done, .blocked, .cancelled])
  func onlyQueuedStepsAreAdmitted(status: StepStatus) {
    let jobs = [Build.job(1, Build.network(1, status))]
    #expect(Scheduler.admissible(jobs: jobs, running: []).isEmpty)
  }

  /// Ordering must be answerable, so ties break on job creation time.
  @Test func admitsTheOlderJobFirst() {
    let jobs = [
      Build.job(1, createdAt: 200, Build.network(1)),
      Build.job(2, createdAt: 100, Build.network(2)),
    ]
    #expect(Scheduler.admissible(jobs: jobs, running: []) == [Build.stepID(2)])
  }

  /// The headline scenario from the design discussion.
  @Test func aFailedChatDownloadDoesNotStopAnIndependentVideoDownload() {
    let chatFailed = Build.network(2, .failed(StepFailure(kind: .noArtifact, summary: "x")))
    let jobs = [Build.job(1,
      Build.network(1),                                    // video, independent
      chatFailed,                                          // chat, failed
      Build.compute(3, .blocked, dependsOn: Build.stepID(2)))]

    #expect(Scheduler.admissible(jobs: jobs, running: []) == [Build.stepID(1)])
  }
}
```

- [ ] **Step 3: Run the test and verify it fails**

Run: `swift test --filter SchedulerAdmissionTests`
Expected: FAIL — `cannot find 'Scheduler' in scope`.

- [ ] **Step 4: Implement `admissible`**

`Sources/OxbowKit/Scheduling/Scheduler.swift`:

```swift
import Foundation

/// The queue's rules, as pure functions.
///
/// Nothing here performs I/O, reads a clock, or touches a process. That is
/// deliberate: it makes every scheduling rule a table-driven unit test rather
/// than something you can only observe by running real downloads.
public enum Scheduler {

  /// Which queued steps may start, given what is already running.
  ///
  /// Three rules, applied in order:
  ///   1. Eligible — status is `.queued` and any dependency is `.done`.
  ///   2. Capacity — at most one running step per resource class.
  ///   3. Order — oldest job first, then step order within the job.
  public static func admissible(jobs: [Job], running: Set<StepID>) -> [StepID] {
    var statusByID: [StepID: StepStatus] = [:]
    for job in jobs {
      for step in job.steps { statusByID[step.id] = step.status }
    }

    var occupied: Set<ResourceClass> = []
    for job in jobs {
      for step in job.steps where running.contains(step.id) {
        occupied.insert(step.kind.resource)
      }
    }

    var admitted: [StepID] = []
    for job in jobs.sorted(by: isOlder) {
      for step in job.steps {
        guard step.status == .queued else { continue }

        if let dependency = step.dependsOn {
          guard statusByID[dependency] == .done else { continue }
        }

        let resource = step.kind.resource
        guard !occupied.contains(resource) else { continue }

        occupied.insert(resource)
        admitted.append(step.id)
      }
    }
    return admitted
  }

  /// Deterministic ordering. Falling back to the id keeps the result stable
  /// when two jobs share a creation timestamp.
  private static func isOlder(_ a: Job, _ b: Job) -> Bool {
    if a.created != b.created { return a.created < b.created }
    return a.id.rawValue.uuidString < b.id.rawValue.uuidString
  }
}
```

- [ ] **Step 5: Run the tests and verify they pass**

Run: `swift test --filter SchedulerAdmissionTests`
Expected: PASS, 12 tests (the `arguments:` case expands to 4).

- [ ] **Step 6: Commit**

```bash
git add Sources/OxbowKit/Scheduling Tests/OxbowKitTests
git commit -m "feat(scheduling): add pure admission function

Class-aware capacity so one download and one render overlap while two
downloads never do, dependency gating, and deterministic oldest-job-first
ordering. No I/O, no clock, no processes — every rule is a table test."
```

---

## Task 8: Scheduler transitions

Completion, blocked propagation, retry, cancel (spec §3).

**Files:**
- Modify: `Sources/OxbowKit/Scheduling/Scheduler.swift`
- Test: `Tests/OxbowKitTests/SchedulerTransitionTests.swift`

**Interfaces:**
- Consumes: `Scheduler.admissible`, `Build` from Task 7; `StepOutcome` from Task 5.
- Produces: `Scheduler.complete(_:with:in:)`, `Scheduler.retry(_:in:)`,
  `Scheduler.cancel(_:in:)`, `Scheduler.cancel(job:in:)` — all mutating `inout [Job]`.

- [ ] **Step 1: Write the failing test**

`Tests/OxbowKitTests/SchedulerTransitionTests.swift`:

```swift
import Foundation
import Testing
@testable import OxbowKit

@Suite("Scheduler transitions")
struct SchedulerTransitionTests {

  private func status(_ jobs: [Job], _ n: Int) -> StepStatus {
    jobs[0].steps.first { $0.id == Build.stepID(n) }!.status
  }

  private var chatThenRender: [Job] {
    [Build.job(1,
      Build.network(1, .running),
      Build.compute(2, .queued, dependsOn: Build.stepID(1)))]
  }

  @Test func successMarksTheStepDoneAndRecordsItsArtifact() {
    var jobs = chatThenRender
    let artifact = URL(filePath: "/tmp/chat.json")
    Scheduler.complete(Build.stepID(1), with: .succeeded(artifact: artifact), in: &jobs)

    #expect(status(jobs, 1) == .done)
    #expect(jobs[0].steps[0].artifact == artifact)
  }

  @Test func failureBlocksDependentsButNotTheFailedStepItself() {
    var jobs = chatThenRender
    let failure = StepFailure(kind: .exited(code: 134), summary: "Invalid VOD")
    Scheduler.complete(Build.stepID(1), with: .failed(failure), in: &jobs)

    #expect(status(jobs, 1) == .failed(failure))
    #expect(status(jobs, 2) == .blocked)
  }

  @Test func cancellationAlsoBlocksDependents() {
    var jobs = chatThenRender
    Scheduler.complete(Build.stepID(1), with: .cancelled, in: &jobs)

    #expect(status(jobs, 1) == .cancelled)
    #expect(status(jobs, 2) == .blocked)
  }

  /// Blocking must reach a dependent's dependents, not just direct children.
  @Test func blockingPropagatesTransitively() {
    var jobs = [Build.job(1,
      Build.network(1, .running),
      Build.compute(2, .queued, dependsOn: Build.stepID(1)),
      Build.compute(3, .queued, dependsOn: Build.stepID(2)))]

    Scheduler.complete(Build.stepID(1), with: .cancelled, in: &jobs)

    #expect(status(jobs, 2) == .blocked)
    #expect(status(jobs, 3) == .blocked)
  }

  /// Retry in place: requeue the failed step AND release what it blocked,
  /// without disturbing siblings that already succeeded.
  @Test func retryRequeuesTheStepAndUnblocksItsDependents() {
    var jobs = [Build.job(1,
      Build.network(9, .done),                                    // succeeded sibling
      Build.network(1, .failed(StepFailure(kind: .noArtifact, summary: "x"))),
      Build.compute(2, .blocked, dependsOn: Build.stepID(1)))]

    Scheduler.retry(Build.stepID(1), in: &jobs)

    #expect(status(jobs, 1) == .queued)
    #expect(status(jobs, 2) == .queued)
    #expect(status(jobs, 9) == .done, "a successful sibling must not be redone")
  }

  @Test func cancellingAJobCancelsEveryUnfinishedStepAndLeavesFinishedOnes() {
    var jobs = [Build.job(1,
      Build.network(1, .done),
      Build.network(2, .running),
      Build.compute(3, .queued))]

    Scheduler.cancel(job: Build.jobID(1), in: &jobs)

    #expect(status(jobs, 1) == .done)
    #expect(status(jobs, 2) == .cancelled)
    #expect(status(jobs, 3) == .cancelled)
  }

  /// After a failure the queue must keep moving on independent work.
  @Test func admissionResumesOnIndependentWorkAfterAFailure() {
    var jobs = [Build.job(1,
      Build.network(1, .running),
      Build.compute(2, .queued, dependsOn: Build.stepID(1)),
      Build.compute(3, .queued))]                                  // independent render

    Scheduler.complete(Build.stepID(1), with: .failed(
      StepFailure(kind: .noArtifact, summary: "x")), in: &jobs)

    #expect(Scheduler.admissible(jobs: jobs, running: []) == [Build.stepID(3)])
  }
}
```

- [ ] **Step 2: Run the test and verify it fails**

Run: `swift test --filter SchedulerTransitionTests`
Expected: FAIL — `type 'Scheduler' has no member 'complete'`.

- [ ] **Step 3: Implement the transitions**

Append inside `enum Scheduler` in `Sources/OxbowKit/Scheduling/Scheduler.swift`:

```swift
  /// Folds a finished step's outcome back in.
  ///
  /// Anything other than success blocks the step's dependents, transitively.
  public static func complete(_ id: StepID, with outcome: StepOutcome, in jobs: inout [Job]) {
    guard let location = locate(id, in: jobs) else { return }

    switch outcome {
    case .succeeded(let artifact):
      jobs[location.job].steps[location.step].status = .done
      jobs[location.job].steps[location.step].artifact = artifact
      return

    case .failed(let failure):
      jobs[location.job].steps[location.step].status = .failed(failure)

    case .cancelled:
      jobs[location.job].steps[location.step].status = .cancelled
    }

    blockDependents(of: id, inJobAt: location.job, in: &jobs)
  }

  /// Requeues a failed step and releases whatever it was blocking.
  /// Successful siblings are untouched — that is the point of retry in place.
  public static func retry(_ id: StepID, in jobs: inout [Job]) {
    guard let location = locate(id, in: jobs) else { return }
    jobs[location.job].steps[location.step].status = .queued
    jobs[location.job].steps[location.step].artifact = nil
    unblockDependents(of: id, inJobAt: location.job, in: &jobs)
  }

  public static func cancel(_ id: StepID, in jobs: inout [Job]) {
    complete(id, with: .cancelled, in: &jobs)
  }

  /// Cancels every unfinished step. Finished steps keep their artifacts.
  public static func cancel(job id: JobID, in jobs: inout [Job]) {
    guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
    for stepIndex in jobs[index].steps.indices {
      switch jobs[index].steps[stepIndex].status {
      case .queued, .blocked, .running:
        jobs[index].steps[stepIndex].status = .cancelled
      case .done, .failed, .cancelled:
        continue
      }
    }
  }

  // MARK: - Private

  private static func locate(_ id: StepID, in jobs: [Job]) -> (job: Int, step: Int)? {
    for (jobIndex, job) in jobs.enumerated() {
      if let stepIndex = job.steps.firstIndex(where: { $0.id == id }) {
        return (jobIndex, stepIndex)
      }
    }
    return nil
  }

  /// Walks forward to a fixed point. Steps have at most one parent, so a single
  /// pass per newly-blocked step terminates.
  private static func blockDependents(of id: StepID, inJobAt jobIndex: Int, in jobs: inout [Job]) {
    var frontier: Set<StepID> = [id]

    while !frontier.isEmpty {
      var next: Set<StepID> = []
      for stepIndex in jobs[jobIndex].steps.indices {
        let step = jobs[jobIndex].steps[stepIndex]
        guard let parent = step.dependsOn, frontier.contains(parent) else { continue }
        guard step.status == .queued || step.status == .running else { continue }
        jobs[jobIndex].steps[stepIndex].status = .blocked
        next.insert(step.id)
      }
      frontier = next
    }
  }

  private static func unblockDependents(of id: StepID, inJobAt jobIndex: Int, in jobs: inout [Job]) {
    var frontier: Set<StepID> = [id]

    while !frontier.isEmpty {
      var next: Set<StepID> = []
      for stepIndex in jobs[jobIndex].steps.indices {
        let step = jobs[jobIndex].steps[stepIndex]
        guard let parent = step.dependsOn, frontier.contains(parent) else { continue }
        guard step.status == .blocked else { continue }
        jobs[jobIndex].steps[stepIndex].status = .queued
        next.insert(step.id)
      }
      frontier = next
    }
  }
```

- [ ] **Step 4: Run all scheduler tests and verify they pass**

Run: `swift test --filter Scheduler`
Expected: PASS, 19 tests.

- [ ] **Step 5: Commit**

```bash
git add Sources/OxbowKit/Scheduling/Scheduler.swift Tests/OxbowKitTests/SchedulerTransitionTests.swift
git commit -m "feat(scheduling): add completion, blocking, retry and cancel

Failure and cancellation block dependents transitively; retry requeues the
step and releases what it blocked without redoing successful siblings.
Cancelling a job spares steps that already finished."
```

---

## Task 9: Argument builder

The single place the CLI invariants are enforced (spec §4). All flag names below were verified against `--help` on version 1.56.5, not assumed.

**Two flags exist purely to stop the subprocess hanging or failing:**

- **`--collision Overwrite` is mandatory.** The default is `Prompt`, which on a
  name collision blocks reading stdin that will never arrive — a subprocess hung
  forever with no output. We always write into our own workspace first, so
  overwriting there is always safe.
- **`--output-args=` must use the equals form** (spec §1.6), or the value's
  leading `-c:v` is parsed as more options.

**Files:**
- Create: `Sources/OxbowKit/Arguments/StepContext.swift`, `ArgumentBuilder.swift`
- Test: `Tests/OxbowKitTests/ArgumentBuilderTests.swift`

**Interfaces:**
- Consumes: `StepKind` and the request types from Task 5.
- Produces: `StepContext`, `ArgumentBuilder.arguments(for:context:) -> [String]`.

- [ ] **Step 1: Write the failing test**

`Tests/OxbowKitTests/ArgumentBuilderTests.swift`:

```swift
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

  private var render: StepKind {
    .renderChat(RenderRequest(bitrateMbps: 3, destination: URL(filePath: "/Users/me/Movies/c.mp4")))
  }

  /// `--banner` is a per-verb option; before the verb it is a parse error.
  @Test func bannerFlagFollowsTheVerb() {
    let a = args(video)
    #expect(a.first == "videodownload")
    let banner = try! #require(a.firstIndex(of: "--banner=false"))
    #expect(banner > 0)
  }

  /// The default is Prompt, which would hang the subprocess forever.
  @Test(arguments: [0, 1, 2, 3])
  func collisionIsNeverLeftAtItsPromptingDefault(index: Int) {
    let kinds: [StepKind] = [
      video,
      .downloadClip(ClipRequest(clipSlug: "s", quality: "480p", destination: URL(filePath: "/tmp/c.mp4"))),
      .downloadChat(ChatRequest(videoID: "1", format: .json)),
      render,
    ]
    let a = args(kinds[index])
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
}
```

- [ ] **Step 2: Run the test and verify it fails**

Run: `swift test --filter ArgumentBuilderTests`
Expected: FAIL — `cannot find 'ArgumentBuilder' in scope`.

- [ ] **Step 3: Create `StepContext`**

`Sources/OxbowKit/Arguments/StepContext.swift`:

```swift
import Foundation

/// Everything a step needs that is not part of the user's request: where to
/// work, where to write, and where the bundled FFmpeg lives.
public struct StepContext: Sendable {
  /// Passed as `--temp-path`. Owned by us and deleted when the step ends,
  /// because the CLI's own cleanup never runs when we kill it.
  public var stepTempDirectory: URL
  /// Where the CLI writes. Inside the job workspace, never the user's folder —
  /// the Swift parent moves the finished file out on success.
  public var outputFile: URL
  public var ffmpegPath: URL
  /// The artifact of `dependsOn`, if this step consumes one.
  public var inputArtifact: URL?

  public init(
    stepTempDirectory: URL,
    outputFile: URL,
    ffmpegPath: URL,
    inputArtifact: URL? = nil)
  {
    self.stepTempDirectory = stepTempDirectory
    self.outputFile = outputFile
    self.ffmpegPath = ffmpegPath
    self.inputArtifact = inputArtifact
  }
}
```

- [ ] **Step 4: Implement the builder**

`Sources/OxbowKit/Arguments/ArgumentBuilder.swift`:

```swift
import Foundation

/// Turns a step into an argv array. Pure, so the CLI's invariants are
/// assertions rather than hopes.
///
/// Flag names verified against TwitchDownloaderCLI 1.56.5 `--help`.
public enum ArgumentBuilder {

  /// Always passed. The default is `Prompt`, which on a name collision blocks
  /// reading a stdin that never arrives — a subprocess hung forever with no
  /// output. We write into our own workspace, so overwriting is always safe.
  private static let collision = ["--collision", "Overwrite"]

  public static func arguments(for kind: StepKind, context: StepContext) -> [String] {
    switch kind {
    case .downloadVideo(let request):
      // `--banner=false` is a per-verb option and must follow the verb.
      var args = ["videodownload", "--banner=false"] + collision
      args += ["--id", request.videoID]
      args += ["-q", request.quality]
      args += ["-o", context.outputFile.path]
      args += ["--temp-path", context.stepTempDirectory.path]
      args += ["--ffmpeg-path", context.ffmpegPath.path]
      args += trim(start: request.trimStart, end: request.trimEnd)
      return args

    case .downloadClip(let request):
      var args = ["clipdownload", "--banner=false"] + collision
      args += ["--id", request.clipSlug]
      args += ["-q", request.quality]
      args += ["-o", context.outputFile.path]
      args += ["--temp-path", context.stepTempDirectory.path]
      args += ["--ffmpeg-path", context.ffmpegPath.path]
      return args

    case .downloadChat(let request):
      // No --ffmpeg-path: chatdownload never invokes FFmpeg.
      var args = ["chatdownload", "--banner=false"] + collision
      args += ["--id", request.videoID]
      args += ["-o", context.outputFile.path]
      args += ["--temp-path", context.stepTempDirectory.path]
      args += trim(start: request.trimStart, end: request.trimEnd)
      if request.isEmbeddingImages { args += ["-E"] }
      return args

    case .renderChat(let request):
      var args = ["chatrender", "--banner=false"] + collision
      args += ["-i", context.inputArtifact?.path ?? ""]
      args += ["-o", context.outputFile.path]
      args += ["--temp-path", context.stepTempDirectory.path]
      args += ["--ffmpeg-path", context.ffmpegPath.path]
      args += ["-w", String(request.width)]
      args += ["-h", String(request.height)]
      args += ["--framerate", String(request.framerate)]
      args += ["--font-size", String(request.fontSize)]

      // The CLI's default is `-c:v libx264`, which is GPL and absent from our
      // LGPL FFmpeg. VideoToolbox is bitrate-targeted; there is no CRF.
      //
      // The equals form is required: a value beginning with `-` is otherwise
      // parsed as more options.
      args += ["--output-args=-c:v h264_videotoolbox -b:v \(request.bitrateMbps)M "
        + "-pix_fmt yuv420p \"{save_path}\""]

      if request.isSharpened {
        // NOT `--sharpening`: that appends smartblur, which configure declares
        // gpl-only and which our build therefore lacks. unsharp was relicensed
        // to LGPL and is present.
        //
        // This restates the CLI's default input args because there is no way to
        // append to them. If upstream changes that default, update this too.
        args += ["--input-args=-framerate {fps} -f rawvideo "
          + "-analyzeduration {max_int} -probesize {max_int} "
          + "-pix_fmt {pix_fmt} -video_size {width}x{height} -i - "
          + "-filter_complex \"unsharp=5:5:1.0\""]
      }
      return args
    }
  }

  /// The CLI accepts `#ms`, `#s`, `#m`, `#h`, or `##:##:##`. Seconds is the
  /// least ambiguous.
  private static func trim(start: Duration?, end: Duration?) -> [String] {
    var args: [String] = []
    if let start { args += ["-b", "\(start.components.seconds)s"] }
    if let end { args += ["-e", "\(end.components.seconds)s"] }
    return args
  }
}
```

- [ ] **Step 5: Run the tests and verify they pass**

Run: `swift test --filter ArgumentBuilderTests`
Expected: PASS, 13 tests.

- [ ] **Step 6: Commit**

```bash
git add Sources/OxbowKit/Arguments Tests/OxbowKitTests/ArgumentBuilderTests.swift
git commit -m "feat(arguments): build argv with the CLI invariants as assertions

Enforces --banner=false after the verb, the --output-args= equals form,
h264_videotoolbox instead of the GPL libx264 default, and unsharp instead of
the GPL smartblur that --sharpening would append.

Also always passes --collision Overwrite. The default is Prompt, which on a
name collision blocks reading a stdin that never arrives — a subprocess hung
forever with no output and no error."
```

---

## Task 10: Process spawning with process groups

The only file in the package with C interop. It exists because Foundation's `Process` cannot do the one thing we need (spec §4).

**Why not `Process`:** it places the child in *our* process group, so
`kill(-pgid, …)` would kill Oxbow itself. The helper spawns FFmpeg as a
grandchild; killing only the helper orphans an FFmpeg that keeps writing into a
directory we consider abandoned (`docs/handoff.md` §3.4). `posix_spawn` with
`POSIX_SPAWN_SETPGROUP` makes the helper its own group leader, so one signal
reaches both.

**Files:**
- Create: `Sources/OxbowKit/Process/Spawn.swift`, `ExitStatus.swift`, `SpawnError.swift`
- Test: `Tests/OxbowKitTests/SpawnTests.swift`

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces: `Spawn`, `ExitStatus`, `SpawnError`, `ProcessSpawner.spawn(executable:arguments:workingDirectory:)`,
  `ProcessSpawner.signal(_:toGroupOf:)`, `ProcessSpawner.wait(_:)`.

- [ ] **Step 1: Write the failing test**

`Tests/OxbowKitTests/SpawnTests.swift`:

```swift
import Foundation
import Testing
@testable import OxbowKit

@Suite("Process spawning", .serialized)
struct SpawnTests {

  /// Writes an executable shell script into a fresh temp directory.
  private func script(_ body: String) throws -> (url: URL, directory: URL) {
    let directory = URL(filePath: NSTemporaryDirectory())
      .appending(path: "oxbow-spawn-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = directory.appending(path: "fixture.sh")
    try "#!/bin/sh\n\(body)\n".write(to: url, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    return (url, directory)
  }

  private func isAlive(_ pid: pid_t) -> Bool { kill(pid, 0) == 0 }

  @Test func capturesStdoutAndExitCode() throws {
    let (url, directory) = try script("echo hello; exit 3")
    let spawned = try ProcessSpawner.spawn(executable: url, arguments: [], workingDirectory: directory)

    let output = String(decoding: spawned.stdout.readDataToEndOfFile(), as: UTF8.self)
    let status = ProcessSpawner.wait(spawned.pid)

    #expect(output.trimmingCharacters(in: .whitespacesAndNewlines) == "hello")
    #expect(status == .exited(3))
  }

  @Test func distinguishesASignalFromAnExitCode() throws {
    let (url, directory) = try script("kill -9 $$")
    let spawned = try ProcessSpawner.spawn(executable: url, arguments: [], workingDirectory: directory)
    #expect(ProcessSpawner.wait(spawned.pid) == .signalled(SIGKILL))
  }

  /// THE test. A helper that spawns a grandchild must not leave it running when
  /// we cancel — that is the orphaned-FFmpeg bug, made automatic.
  @Test func killingTheGroupAlsoKillsGrandchildren() throws {
    let (url, directory) = try script("""
      sleep 300 &
      echo $!
      sleep 300
      """)
    let spawned = try ProcessSpawner.spawn(executable: url, arguments: [], workingDirectory: directory)

    // First line of stdout is the grandchild's pid.
    var buffer = Data()
    while !buffer.contains(UInt8(ascii: "\n")) {
      buffer.append(spawned.stdout.availableData)
    }
    let grandchild = pid_t(String(decoding: buffer, as: UTF8.self)
      .trimmingCharacters(in: .whitespacesAndNewlines))!

    #expect(isAlive(spawned.pid))
    #expect(isAlive(grandchild))

    ProcessSpawner.signal(SIGKILL, toGroupOf: spawned.pid)
    _ = ProcessSpawner.wait(spawned.pid)

    // Give the kernel a moment to reap.
    for _ in 0..<50 where isAlive(grandchild) { usleep(20_000) }

    #expect(!isAlive(grandchild), "FFmpeg would have been orphaned here")
  }

  @Test func reportsSpawnFailureForAMissingExecutable() {
    #expect(throws: SpawnError.self) {
      try ProcessSpawner.spawn(
        executable: URL(filePath: "/nonexistent/binary"),
        arguments: [],
        workingDirectory: URL(filePath: NSTemporaryDirectory()))
    }
  }
}
```

- [ ] **Step 2: Run the test and verify it fails**

Run: `swift test --filter SpawnTests`
Expected: FAIL — `cannot find 'ProcessSpawner' in scope`.

- [ ] **Step 3: Create the result types**

`Sources/OxbowKit/Process/ExitStatus.swift`:

```swift
/// How a child process ended.
///
/// Keeping these apart is what lets us tell "the user cancelled it" from "it
/// crashed" — a distinction Foundation's `Process` blurs.
public enum ExitStatus: Sendable, Equatable {
  case exited(Int32)
  case signalled(Int32)
}
```

`Sources/OxbowKit/Process/SpawnError.swift`:

```swift
public enum SpawnError: Error, Equatable {
  case pipeFailed(Int32)
  case spawnFailed(code: Int32, message: String)
}
```

- [ ] **Step 4: Implement the spawner**

`Sources/OxbowKit/Process/Spawn.swift`:

```swift
import Darwin
import Foundation

/// A running child process and its captured output streams.
public struct Spawn: @unchecked Sendable {
  public let pid: pid_t
  public let stdout: FileHandle
  public let stderr: FileHandle
}

public enum ProcessSpawner {

  /// Spawns `executable` in **its own process group**.
  ///
  /// The process group is the entire reason this exists rather than using
  /// Foundation's `Process`, which places the child in ours — making
  /// `kill(-pgid, …)` fatal to Oxbow itself.
  public static func spawn(
    executable: URL,
    arguments: [String],
    workingDirectory: URL)
    throws -> Spawn
  {
    var outPipe: [Int32] = [0, 0]
    var errPipe: [Int32] = [0, 0]
    guard pipe(&outPipe) == 0 else { throw SpawnError.pipeFailed(errno) }
    guard pipe(&errPipe) == 0 else {
      close(outPipe[0]); close(outPipe[1])
      throw SpawnError.pipeFailed(errno)
    }

    var actions: posix_spawn_file_actions_t?
    posix_spawn_file_actions_init(&actions)
    defer { posix_spawn_file_actions_destroy(&actions) }

    posix_spawn_file_actions_adddup2(&actions, outPipe[1], STDOUT_FILENO)
    posix_spawn_file_actions_adddup2(&actions, errPipe[1], STDERR_FILENO)
    // The child must not retain either end beyond the dup2 targets, or the
    // read side never sees EOF and readDataToEndOfFile hangs forever.
    posix_spawn_file_actions_addclose(&actions, outPipe[0])
    posix_spawn_file_actions_addclose(&actions, outPipe[1])
    posix_spawn_file_actions_addclose(&actions, errPipe[0])
    posix_spawn_file_actions_addclose(&actions, errPipe[1])
    posix_spawn_file_actions_addchdir_np(&actions, workingDirectory.path)

    var attributes: posix_spawnattr_t?
    posix_spawnattr_init(&attributes)
    defer { posix_spawnattr_destroy(&attributes) }
    // pgroup 0 means "become your own group leader", so pgid == pid.
    posix_spawnattr_setpgroup(&attributes, 0)
    posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP))

    let argv: [UnsafeMutablePointer<CChar>?] =
      ([executable.path] + arguments).map { strdup($0) } + [nil]
    defer { for argument in argv where argument != nil { free(argument) } }

    var pid: pid_t = 0
    let result = posix_spawn(&pid, executable.path, &actions, &attributes, argv, environ)

    // Close our copies of the write ends, or we never observe EOF.
    close(outPipe[1])
    close(errPipe[1])

    guard result == 0 else {
      close(outPipe[0])
      close(errPipe[0])
      throw SpawnError.spawnFailed(code: result, message: String(cString: strerror(result)))
    }

    return Spawn(
      pid: pid,
      stdout: FileHandle(fileDescriptor: outPipe[0], closeOnDealloc: true),
      stderr: FileHandle(fileDescriptor: errPipe[0], closeOnDealloc: true))
  }

  /// Signals the child's whole process group. A negative pid means "group",
  /// and because we set pgroup 0 at spawn, the group id equals the child's pid.
  public static func signal(_ signalNumber: Int32, toGroupOf pid: pid_t) {
    kill(-pid, signalNumber)
  }

  /// Blocks until the child ends. Swift does not expose the `WIFEXITED` family
  /// of C macros, so the wait status is decoded by hand.
  public static func wait(_ pid: pid_t) -> ExitStatus {
    var raw: Int32 = 0
    while waitpid(pid, &raw, 0) == -1 && errno == EINTR { continue }

    let terminatingSignal = raw & 0x7F
    if terminatingSignal == 0 {
      return .exited((raw >> 8) & 0xFF)
    }
    return .signalled(terminatingSignal)
  }
}
```

- [ ] **Step 5: Run the tests and verify they pass**

Run: `swift test --filter SpawnTests`
Expected: PASS, 4 tests. `killingTheGroupAlsoKillsGrandchildren` is the one that matters; if it fails, `POSIX_SPAWN_SETPGROUP` is not taking effect.

- [ ] **Step 6: Commit**

```bash
git add Sources/OxbowKit/Process Tests/OxbowKitTests/SpawnTests.swift
git commit -m "feat(process): spawn helpers in their own process group

Foundation's Process puts the child in our group, so signalling that group
would kill Oxbow. posix_spawn with POSIX_SPAWN_SETPGROUP makes the helper a
group leader, so one signal reaches the FFmpeg it spawns as a grandchild.

The grandchild test is a direct automated check for the orphaned-FFmpeg bug —
otherwise the kind of thing you discover from a user's disk filling up."
```

---

## Task 11: HelperProcess

Drives one CLI invocation: spawn, stream output through the parser, capture stderr, wait, and cancel hard (spec §4).

**Files:**
- Create: `Sources/OxbowKit/Process/Launch.swift`, `RunResult.swift`, `HelperProcess.swift`
- Test: `Tests/OxbowKitTests/HelperProcessTests.swift`

**Interfaces:**
- Consumes: `ProcessSpawner`, `ExitStatus` (Task 10); `StatusLineParser`, `ParsedLine` (Tasks 1–3).
- Produces: `Launch`, `RunResult`, `HelperProcess.run(_:onOutput:)`, `HelperProcess.cancel()`.

- [ ] **Step 1: Write the failing test**

`Tests/OxbowKitTests/HelperProcessTests.swift`:

```swift
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
```

- [ ] **Step 2: Run the test and verify it fails**

Run: `swift test --filter HelperProcessTests`
Expected: FAIL — `cannot find 'HelperProcess' in scope`.

- [ ] **Step 3: Create the value types**

`Sources/OxbowKit/Process/Launch.swift`:

```swift
import Foundation

/// One fully-resolved CLI invocation.
public struct Launch: Sendable {
  public var executable: URL
  public var arguments: [String]
  /// The step's temp directory. The CLI writes its ffmpeg log here.
  public var workingDirectory: URL

  public init(executable: URL, arguments: [String], workingDirectory: URL) {
    self.executable = executable
    self.arguments = arguments
    self.workingDirectory = workingDirectory
  }
}
```

`Sources/OxbowKit/Process/RunResult.swift`:

```swift
public struct RunResult: Sendable {
  public var status: ExitStatus
  /// Kept whole. The CLI reports failures as unhandled exceptions with a stack
  /// trace here, and the useful sentence has to be extracted from it.
  public var standardError: String
}
```

- [ ] **Step 4: Implement the actor**

`Sources/OxbowKit/Process/HelperProcess.swift`:

```swift
import Darwin
import Foundation

/// Runs one CLI invocation to completion.
///
/// Cancellation is deliberately blunt: the CLI passes a CancellationToken that
/// can never fire and installs no signal handler, so there is no cooperative
/// path. SIGTERM first is purely for FFmpeg's benefit — it closes its output
/// file on receipt — and SIGKILL follows regardless.
public actor HelperProcess {
  private var spawned: Spawn?
  private var isCancelled = false

  public init() {}

  public func run(
    _ launch: Launch,
    onOutput: @escaping @Sendable (ParsedLine) async -> Void)
    async throws -> RunResult
  {
    let spawned = try ProcessSpawner.spawn(
      executable: launch.executable,
      arguments: launch.arguments,
      workingDirectory: launch.workingDirectory)
    self.spawned = spawned

    // Cancelled between the caller's decision and the spawn actually happening.
    if isCancelled {
      ProcessSpawner.signal(SIGKILL, toGroupOf: spawned.pid)
    }

    let stdoutHandle = spawned.stdout
    let stderrHandle = spawned.stderr

    let stdoutPump = Task.detached {
      var parser = StatusLineParser()
      while true {
        let data = stdoutHandle.availableData
        if data.isEmpty { break }
        for line in parser.consume(data) { await onOutput(line) }
      }
      if let tail = parser.finish() { await onOutput(tail) }
    }

    let stderrPump = Task.detached { () -> String in
      var accumulated = Data()
      while true {
        let data = stderrHandle.availableData
        if data.isEmpty { break }
        accumulated.append(data)
      }
      return String(decoding: accumulated, as: UTF8.self)
    }

    let pid = spawned.pid
    let status = await Task.detached { ProcessSpawner.wait(pid) }.value

    await stdoutPump.value
    let standardError = await stderrPump.value

    self.spawned = nil
    return RunResult(status: status, standardError: standardError)
  }

  /// Signals the whole process group so the helper's FFmpeg goes with it.
  public func cancel() async {
    isCancelled = true
    guard let spawned else { return }

    ProcessSpawner.signal(SIGTERM, toGroupOf: spawned.pid)
    try? await Task.sleep(for: .seconds(2))
    ProcessSpawner.signal(SIGKILL, toGroupOf: spawned.pid)
  }
}
```

- [ ] **Step 5: Run the tests and verify they pass**

Run: `swift test --filter HelperProcessTests`
Expected: PASS, 3 tests.

- [ ] **Step 6: Commit**

```bash
git add Sources/OxbowKit/Process Tests/OxbowKitTests/HelperProcessTests.swift
git commit -m "feat(process): add HelperProcess driving one CLI invocation

Streams stdout through the incremental parser, captures stderr whole for
failure extraction, and cancels by signalling the process group. Cancellation
is blunt by necessity: the CLI passes a CancellationToken that can never fire
and installs no signal handler, so SIGTERM exists only so FFmpeg closes its
output file before SIGKILL arrives."
```

---

## Task 12: Persistence and reconciliation

Queue state survives a crash; nothing else does (spec §5).

**Files:**
- Create: `Sources/OxbowKit/Persistence/QueueStore.swift`, `Reconciler.swift`
- Test: `Tests/OxbowKitTests/QueueStoreTests.swift`, `ReconcilerTests.swift`

**Interfaces:**
- Consumes: `Job`, `Step`, `StepStatus`, `StepFailure` (Task 5); `Build` (Task 7).
- Produces: `QueueStore(fileURL:)`, `.load()`, `.save(_:)`, `Reconciler.reconcile(_:artifactExists:)`.

- [ ] **Step 1: Write the failing tests**

`Tests/OxbowKitTests/QueueStoreTests.swift`:

```swift
import Foundation
import Testing
@testable import OxbowKit

@Suite("QueueStore")
struct QueueStoreTests {

  private func temporaryFile() -> URL {
    URL(filePath: NSTemporaryDirectory())
      .appending(path: "oxbow-queue-\(UUID().uuidString).json")
  }

  @Test func roundTripsJobs() throws {
    let url = temporaryFile()
    let store = QueueStore(fileURL: url)
    let jobs = [Build.job(1, Build.network(1, .done), Build.compute(2, .queued))]

    try store.save(jobs)
    #expect(try store.load() == jobs)
  }

  @Test func loadsEmptyWhenNoFileExists() throws {
    #expect(try QueueStore(fileURL: temporaryFile()).load().isEmpty)
  }

  /// An unrecognised schema must not crash or guess; it is set aside.
  @Test func setsAsideAnUnknownSchemaVersion() throws {
    let url = temporaryFile()
    try #"{"version": 9999, "jobs": []}"#.write(to: url, atomically: true, encoding: .utf8)

    let store = QueueStore(fileURL: url)
    #expect(try store.load().isEmpty)
    #expect(FileManager.default.fileExists(atPath: url.appendingPathExtension("bak").path))
  }

  /// A partially written file must never replace a good one.
  @Test func writesAtomically() throws {
    let url = temporaryFile()
    let store = QueueStore(fileURL: url)
    try store.save([Build.job(1, Build.network(1))])
    try store.save([Build.job(2, Build.network(2)), Build.job(3, Build.network(3))])
    #expect(try store.load().count == 2)
  }
}
```

`Tests/OxbowKitTests/ReconcilerTests.swift`:

```swift
import Foundation
import Testing
@testable import OxbowKit

@Suite("Reconciler")
struct ReconcilerTests {

  private func status(_ jobs: [Job], _ n: Int) -> StepStatus {
    jobs[0].steps.first { $0.id == Build.stepID(n) }!.status
  }

  /// Nothing resumes, so a step persisted as running died with the app.
  @Test func runningStepsBecomeInterrupted() {
    let jobs = [Build.job(1, Build.network(1, .running))]
    let out = Reconciler.reconcile(jobs) { _ in true }
    #expect(out[0].steps[0].status == .failed(StepFailure(kind: .interrupted, summary: "Interrupted")))
  }

  /// The check that stops a finished 4 GB download being redone.
  @Test func doneStepsKeepTheirStatusWhenTheArtifactStillExists() {
    var step = Build.network(1, .done)
    step.artifact = URL(filePath: "/Users/me/Movies/v.mp4")
    let out = Reconciler.reconcile([Build.job(1, step)]) { _ in true }
    #expect(status(out, 1) == .done)
  }

  /// An intermediate that only ever lived in the job workspace is gone.
  @Test func doneStepsRequeueWhenTheirArtifactVanished() {
    var step = Build.network(1, .done)
    step.artifact = URL(filePath: "/tmp/gone/chat.json")
    let out = Reconciler.reconcile([Build.job(1, step)]) { _ in false }
    #expect(status(out, 1) == .queued)
    #expect(out[0].steps[0].artifact == nil)
  }

  @Test func doneStepsWithNoRecordedArtifactRequeue() {
    let out = Reconciler.reconcile([Build.job(1, Build.network(1, .done))]) { _ in true }
    #expect(status(out, 1) == .queued)
  }

  @Test(arguments: [StepStatus.queued, .blocked, .cancelled])
  func otherStatusesAreLeftAlone(status input: StepStatus) {
    let out = Reconciler.reconcile([Build.job(1, Build.network(1, input))]) { _ in true }
    #expect(status(out, 1) == input)
  }
}
```

- [ ] **Step 2: Run the tests and verify they fail**

Run: `swift test --filter "QueueStoreTests|ReconcilerTests"`
Expected: FAIL — neither type exists.

- [ ] **Step 3: Implement `QueueStore`**

`Sources/OxbowKit/Persistence/QueueStore.swift`:

```swift
import Foundation

/// Reads and writes the queue file.
///
/// Writes go through a temporary file and `replaceItemAt`, because a truncated
/// queue.json from a crash mid-write would lose the entire queue — a trivially
/// avoidable class of bug.
public struct QueueStore: Sendable {
  private struct Envelope: Codable {
    static let currentVersion = 1
    var version: Int
    var jobs: [Job]
  }

  public let fileURL: URL

  public init(fileURL: URL) {
    self.fileURL = fileURL
  }

  public func load() throws -> [Job] {
    guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }

    let data = try Data(contentsOf: fileURL)
    let envelope = try JSONDecoder().decode(Envelope.self, from: data)

    // Do not guess at a schema we do not understand, and do not crash on it.
    guard envelope.version == Envelope.currentVersion else {
      let backup = fileURL.appendingPathExtension("bak")
      try? FileManager.default.removeItem(at: backup)
      try FileManager.default.moveItem(at: fileURL, to: backup)
      return []
    }

    return envelope.jobs
  }

  public func save(_ jobs: [Job]) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(Envelope(version: Envelope.currentVersion, jobs: jobs))

    try FileManager.default.createDirectory(
      at: fileURL.deletingLastPathComponent(),
      withIntermediateDirectories: true)

    let scratch = fileURL.deletingLastPathComponent()
      .appending(path: ".\(fileURL.lastPathComponent).\(UUID().uuidString)")
    try data.write(to: scratch)

    if FileManager.default.fileExists(atPath: fileURL.path) {
      _ = try FileManager.default.replaceItemAt(fileURL, withItemAt: scratch)
    } else {
      try FileManager.default.moveItem(at: scratch, to: fileURL)
    }
  }
}
```

- [ ] **Step 4: Implement `Reconciler`**

`Sources/OxbowKit/Persistence/Reconciler.swift`:

```swift
import Foundation

/// Brings a loaded queue back in line with what is actually on disk.
///
/// Nothing resumes, but a naive "reset everything" would redo a completed 4 GB
/// video download because a later render failed. The artifact check is what
/// makes the distinction: a file moved to the user's folder survives, an
/// intermediate that only ever lived in the job workspace does not.
public enum Reconciler {

  public static func reconcile(
    _ jobs: [Job],
    artifactExists: (URL) -> Bool)
    -> [Job]
  {
    jobs.map { job in
      var job = job
      for index in job.steps.indices {
        switch job.steps[index].status {
        case .running:
          // The app died while this was running; there is no resume.
          job.steps[index].status = .failed(
            StepFailure(kind: .interrupted, summary: "Interrupted"))
          job.steps[index].artifact = nil

        case .done:
          guard let artifact = job.steps[index].artifact, artifactExists(artifact) else {
            job.steps[index].status = .queued
            job.steps[index].artifact = nil
            continue
          }

        case .queued, .blocked, .failed, .cancelled:
          continue
        }
      }
      return job
    }
  }
}
```

- [ ] **Step 5: Run the tests and verify they pass**

Run: `swift test --filter "QueueStoreTests|ReconcilerTests"`
Expected: PASS, 11 tests.

- [ ] **Step 6: Commit**

```bash
git add Sources/OxbowKit/Persistence Tests/OxbowKitTests/QueueStoreTests.swift Tests/OxbowKitTests/ReconcilerTests.swift
git commit -m "feat(persistence): add atomic queue store and load-time reconciliation

Writes go through replaceItemAt so a crash mid-write cannot truncate the
queue, and an unrecognised schema version is set aside rather than guessed at.

Reconciliation checks whether each done step's artifact still exists, which is
what stops a finished multi-gigabyte download being redone because a later
step failed, while correctly requeueing intermediates that only ever lived in
the job workspace."
```

---

## Task 13: Workspace and failure interpretation

Two pure-ish pieces the engine needs (spec §5, §6).

**Files:**
- Create: `Sources/OxbowKit/Persistence/Workspace.swift`
- Create: `Sources/OxbowKit/Model/FailureInterpreter.swift`
- Test: `Tests/OxbowKitTests/WorkspaceTests.swift`, `FailureInterpreterTests.swift`

**Interfaces:**
- Consumes: `JobID`, `StepID`, `StepFailure` (Task 5); `ExitStatus` (Task 10).
- Produces: `Workspace`, `FailureInterpreter.interpret(exitStatus:standardError:artifactExists:)`.

- [ ] **Step 1: Write the failing tests**

`Tests/OxbowKitTests/FailureInterpreterTests.swift`:

```swift
import Foundation
import Testing
@testable import OxbowKit

@Suite("Failure interpretation")
struct FailureInterpreterTests {

  private func interpret(
    _ status: ExitStatus,
    _ stderr: String = "",
    artifactExists: Bool = true)
    -> StepFailure?
  {
    FailureInterpreter.interpret(
      exitStatus: status, standardError: stderr, artifactExists: artifactExists)
  }

  /// Success is an artifact, not an exit code. The CLI's Main returns void, so
  /// a zero exit proves nothing on its own.
  @Test func successRequiresAnArtifactNotJustAZeroExit() {
    #expect(interpret(.exited(0), artifactExists: true) == nil)
    #expect(interpret(.exited(0), artifactExists: false)?.kind == .noArtifact)
  }

  @Test func distinguishesACrashFromAnExitCode() {
    #expect(interpret(.signalled(SIGSEGV), artifactExists: false)?.kind == .signalled(SIGSEGV))
    #expect(interpret(.exited(134), artifactExists: false)?.kind == .exited(code: 134))
  }

  /// Real captured stderr. The useful sentence is buried in a stack trace.
  @Test func extractsTheInnermostExceptionMessage() throws {
    let stderr = """
      Unhandled exception. System.AggregateException: One or more errors occurred. (Invalid VOD, deleted/expired VOD possibly?)
       ---> System.NullReferenceException: Invalid VOD, deleted/expired VOD possibly?
         at TwitchDownloaderCore.VideoDownloader.DownloadAsyncImpl(...)
      """
    let failure = try #require(interpret(.exited(134), stderr, artifactExists: false))
    #expect(failure.summary == "This VOD no longer exists or has expired.")
    #expect(failure.detail == stderr, "the full trace is kept for bug reports")
  }

  /// The most common real-world failure for a Twitch downloader.
  @Test func recognisesSubscriberOnlyVods() throws {
    let stderr = "Unhandled exception. System.Exception: vod_manifest_restricted"
    let failure = try #require(interpret(.exited(134), stderr, artifactExists: false))
    #expect(failure.summary == "This is a subscriber-only VOD.")
  }

  @Test func fallsBackToTheExtractedSentenceForUnknownErrors() throws {
    let stderr = """
      Unhandled exception. System.AggregateException: One or more errors occurred. (Disk full)
       ---> System.IOException: No space left on device
         at Something(...)
      """
    let failure = try #require(interpret(.exited(134), stderr, artifactExists: false))
    #expect(failure.summary == "No space left on device")
  }

  /// A stack trace must never become the user-facing sentence.
  @Test func neverSurfacesAStackTraceAsTheSummary() throws {
    let stderr = "   at TwitchDownloaderCore.VideoDownloader.DownloadAsyncImpl(...)"
    let failure = try #require(interpret(.exited(1), stderr, artifactExists: false))
    #expect(!failure.summary.contains("   at "))
  }
}
```

`Tests/OxbowKitTests/WorkspaceTests.swift`:

```swift
import Foundation
import Testing
@testable import OxbowKit

@Suite("Workspace")
struct WorkspaceTests {

  private func makeWorkspace() -> Workspace {
    Workspace(root: URL(filePath: NSTemporaryDirectory())
      .appending(path: "oxbow-ws-\(UUID().uuidString)"))
  }

  @Test func createsAndRemovesAStepDirectory() throws {
    let workspace = makeWorkspace()
    let job = Build.jobID(1)
    let step = Build.stepID(1)

    let directory = try workspace.prepareStep(job: job, step: step)
    #expect(FileManager.default.fileExists(atPath: directory.path))

    workspace.removeStep(job: job, step: step)
    #expect(!FileManager.default.fileExists(atPath: directory.path))
  }

  /// Intermediates must outlive the step that produced them, so they live in
  /// the job workspace rather than a step directory.
  @Test func artifactsDirectoryOutlivesIndividualSteps() throws {
    let workspace = makeWorkspace()
    let job = Build.jobID(1)

    let artifacts = try workspace.prepareArtifacts(job: job)
    _ = try workspace.prepareStep(job: job, step: Build.stepID(1))
    workspace.removeStep(job: job, step: Build.stepID(1))

    #expect(FileManager.default.fileExists(atPath: artifacts.path))
  }

  /// Launch sweep: nothing in the workspace can ever be reused.
  @Test func removeAllClearsTheEntireRoot() throws {
    let workspace = makeWorkspace()
    _ = try workspace.prepareStep(job: Build.jobID(1), step: Build.stepID(1))

    workspace.removeAll()
    #expect(!FileManager.default.fileExists(atPath: workspace.root.path))
  }
}
```

- [ ] **Step 2: Run the tests and verify they fail**

Run: `swift test --filter "FailureInterpreterTests|WorkspaceTests"`
Expected: FAIL — neither type exists.

- [ ] **Step 3: Implement `FailureInterpreter`**

`Sources/OxbowKit/Model/FailureInterpreter.swift`:

```swift
import Foundation

/// Turns a finished process into either success or a human-readable failure.
///
/// The CLI's `Main` returns void, so nothing sets an exit code; a bad VOD id
/// exits 134 (SIGABRT) with an unhandled .NET exception on stderr. The artifact
/// is therefore the success criterion and the exit code merely corroborates.
public enum FailureInterpreter {

  /// Returns nil when the step succeeded.
  public static func interpret(
    exitStatus: ExitStatus,
    standardError: String,
    artifactExists: Bool)
    -> StepFailure?
  {
    if artifactExists, case .exited(0) = exitStatus { return nil }

    let kind: StepFailure.Kind
    switch exitStatus {
    case .signalled(let signalNumber):
      kind = .signalled(signalNumber)
    case .exited(0):
      kind = .noArtifact
    case .exited(let code):
      kind = .exited(code: code)
    }

    return StepFailure(
      kind: kind,
      summary: summarise(standardError),
      detail: standardError.isEmpty ? nil : standardError)
  }

  /// Known failures get a real sentence; everything else gets the innermost
  /// exception message. A stack trace is never the summary.
  private static func summarise(_ standardError: String) -> String {
    if standardError.contains("vod_manifest_restricted")
      || standardError.contains("unauthorized_entitlements")
    {
      return "This is a subscriber-only VOD."
    }
    if standardError.contains("Invalid VOD, deleted/expired VOD possibly?") {
      return "This VOD no longer exists or has expired."
    }

    let lines = standardError
      .split(separator: "\n", omittingEmptySubsequences: true)
      .map { $0.trimmingCharacters(in: .whitespaces) }

    // .NET nests inner exceptions as `---> Type: message`. The last one is the
    // root cause and carries the most specific message.
    if let innermost = lines.last(where: { $0.hasPrefix("---> ") }),
       let message = innermost.split(separator: ": ", maxSplits: 1).last
    {
      return String(message)
    }

    // Otherwise the first line that is not a stack frame.
    if let first = lines.first(where: { !$0.hasPrefix("at ") }), !first.isEmpty {
      return first
    }

    return "The download tool failed without reporting a reason."
  }
}
```

- [ ] **Step 4: Implement `Workspace`**

`Sources/OxbowKit/Persistence/Workspace.swift`:

```swift
import Foundation

/// Owns the on-disk scratch space for jobs.
///
/// Per job rather than per step, because chained steps hand artifacts to each
/// other and an intermediate must outlive the step that produced it.
///
/// We own this rather than letting the CLI manage its own cache because the
/// CLI's cleanup sits in a `finally` block that never runs when we kill it.
public struct Workspace: Sendable {
  public let root: URL

  public init(root: URL) {
    self.root = root
  }

  public func jobDirectory(_ job: JobID) -> URL {
    root.appending(path: "jobs/\(job.rawValue.uuidString)")
  }

  /// Passed to the CLI as `--temp-path`.
  public func stepDirectory(job: JobID, step: StepID) -> URL {
    jobDirectory(job).appending(path: "step-\(step.rawValue.uuidString)")
  }

  /// Intermediates handed between steps.
  public func artifactsDirectory(_ job: JobID) -> URL {
    jobDirectory(job).appending(path: "artifacts")
  }

  @discardableResult
  public func prepareStep(job: JobID, step: StepID) throws -> URL {
    let directory = stepDirectory(job: job, step: step)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
  }

  @discardableResult
  public func prepareArtifacts(job: JobID) throws -> URL {
    let directory = artifactsDirectory(job)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
  }

  /// Correct however the process died — graceful exit, cancellation, or crash.
  public func removeStep(job: JobID, step: StepID) {
    try? FileManager.default.removeItem(at: stepDirectory(job: job, step: step))
  }

  public func removeJob(_ job: JobID) {
    try? FileManager.default.removeItem(at: jobDirectory(job))
  }

  /// Launch sweep. Nothing here can ever be reused, so there is no case to
  /// reason about and no way for a power loss to leak tens of gigabytes.
  public func removeAll() {
    try? FileManager.default.removeItem(at: root)
  }
}
```

- [ ] **Step 5: Run the tests and verify they pass**

Run: `swift test --filter "FailureInterpreterTests|WorkspaceTests"`
Expected: PASS, 9 tests.

- [ ] **Step 6: Commit**

```bash
git add Sources/OxbowKit/Model/FailureInterpreter.swift Sources/OxbowKit/Persistence/Workspace.swift Tests/OxbowKitTests/FailureInterpreterTests.swift Tests/OxbowKitTests/WorkspaceTests.swift
git commit -m "feat(model): interpret CLI failures and own the job workspace

Success is the artifact, not the exit code: the CLI's Main returns void so a
zero exit proves nothing. Known failures — deleted VODs and subscriber-only
VODs — get real sentences; everything else gets the innermost .NET exception
message, and a stack trace is never the summary.

The workspace is per job rather than per step so intermediates outlive the
step that produced them, and we own it because the CLI's cleanup lives in a
finally block that never runs when we kill it."
```

---

## Task 14: QueueEngine

The one actor, and the only place side effects happen (spec §3). Everything before this was built so that this file is small and mostly plumbing.

**Files:**
- Create: `Sources/OxbowKit/Process/HelperProcessing.swift`
- Create: `Sources/OxbowKit/Engine/QueueEngine.swift`
- Test: `Tests/OxbowKitTests/QueueEngineTests.swift`

**Interfaces:**
- Consumes: everything from Tasks 1–13.
- Produces: `HelperProcessing`, `QueueEngine`, `QueueEngine.Configuration`.

- [ ] **Step 1: Create the protocol that makes the engine testable**

`Sources/OxbowKit/Process/HelperProcessing.swift`:

```swift
/// What the engine needs from a running helper.
///
/// A protocol solely so tests can substitute a fake and exercise the engine's
/// logic without spawning processes. `HelperProcess` is the only real
/// implementation.
public protocol HelperProcessing: Sendable {
  func run(
    _ launch: Launch,
    onOutput: @escaping @Sendable (ParsedLine) async -> Void)
    async throws -> RunResult

  func cancel() async
}

extension HelperProcess: HelperProcessing {}
```

- [ ] **Step 2: Write the failing test**

`Tests/OxbowKitTests/QueueEngineTests.swift`:

```swift
import Foundation
import Testing
@testable import OxbowKit

/// A helper that writes whatever the test tells it to and reports a chosen status.
actor FakeHelper: HelperProcessing {
  enum Behaviour: Sendable {
    case succeeds
    case failsWithoutArtifact(stderr: String)
  }

  private let behaviour: Behaviour
  init(_ behaviour: Behaviour) { self.behaviour = behaviour }

  func run(
    _ launch: Launch,
    onOutput: @escaping @Sendable (ParsedLine) async -> Void)
    async throws -> RunResult
  {
    await onOutput(.status(StepProgress(phase: "Working", fraction: 0.5)))

    switch behaviour {
    case .succeeds:
      // The engine's success criterion is the artifact, so produce one.
      if let output = Self.outputPath(in: launch.arguments) {
        FileManager.default.createFile(atPath: output, contents: Data("x".utf8))
      }
      return RunResult(status: .exited(0), standardError: "")

    case .failsWithoutArtifact(let stderr):
      return RunResult(status: .exited(134), standardError: stderr)
    }
  }

  func cancel() async {}

  private static func outputPath(in arguments: [String]) -> String? {
    guard let index = arguments.firstIndex(of: "-o"), index + 1 < arguments.count else { return nil }
    return arguments[index + 1]
  }
}

@Suite("QueueEngine", .serialized)
struct QueueEngineTests {

  private func makeEngine(_ behaviour: FakeHelper.Behaviour) -> (QueueEngine, URL) {
    let root = URL(filePath: NSTemporaryDirectory())
      .appending(path: "oxbow-engine-\(UUID().uuidString)")
    let engine = QueueEngine(configuration: .init(
      helperExecutable: URL(filePath: "/usr/bin/true"),
      ffmpegPath: URL(filePath: "/usr/bin/true"),
      workspace: Workspace(root: root),
      store: QueueStore(fileURL: root.appending(path: "queue.json")),
      makeProcess: { FakeHelper(behaviour) }))
    return (engine, root)
  }

  private var chatAndRender: JobTemplate {
    .chatAndRender(
      ChatRequest(videoID: "2844548319", format: .json),
      RenderRequest(destination: URL(filePath: NSTemporaryDirectory())
        .appending(path: "render-\(UUID().uuidString).mp4")))
  }

  /// Waits for the queue to stop having runnable work, or fails the test.
  private func settle(_ engine: QueueEngine) async throws {
    for _ in 0..<200 {
      if await engine.isIdle { return }
      try await Task.sleep(for: .milliseconds(25))
    }
    Issue.record("queue did not settle")
  }

  @Test func runsDependentStepsInOrderAndCompletesTheJob() async throws {
    let (engine, _) = makeEngine(.succeeds)
    try await engine.start()
    await engine.enqueue(chatAndRender, title: "test")
    try await settle(engine)

    let jobs = await engine.currentJobs
    #expect(jobs.count == 1)
    #expect(jobs[0].steps.allSatisfy { $0.status == .done })
    #expect(jobs[0].status == .done)
  }

  /// The scenario the whole failure model exists for.
  @Test func aFailedDependencyBlocksItsDependent() async throws {
    let (engine, _) = makeEngine(.failsWithoutArtifact(
      stderr: "Unhandled exception. System.Exception: vod_manifest_restricted"))
    try await engine.start()
    await engine.enqueue(chatAndRender, title: "test")
    try await settle(engine)

    let steps = await engine.currentJobs[0].steps
    guard case .failed(let failure) = steps[0].status else {
      Issue.record("expected the chat download to fail")
      return
    }
    #expect(failure.summary == "This is a subscriber-only VOD.")
    #expect(steps[1].status == .blocked, "the render must not run")
  }

  @Test func persistsAcrossRestart() async throws {
    let (engine, root) = makeEngine(.succeeds)
    try await engine.start()
    await engine.enqueue(chatAndRender, title: "persisted")
    try await settle(engine)
    await engine.flush()

    let reloaded = try QueueStore(fileURL: root.appending(path: "queue.json")).load()
    #expect(reloaded.count == 1)
    #expect(reloaded[0].title == "persisted")
  }

  @Test func publishesSnapshotsAsWorkProgresses() async throws {
    let (engine, _) = makeEngine(.succeeds)
    try await engine.start()

    let received = Collected2()
    let observer = Task {
      for await snapshot in await engine.snapshots {
        await received.append(snapshot)
        if snapshot.first?.status == .done { break }
      }
    }

    await engine.enqueue(chatAndRender, title: "test")
    try await settle(engine)
    observer.cancel()

    #expect(await received.count > 1, "expected more than one snapshot")
  }
}

actor Collected2 {
  private(set) var count = 0
  func append(_ snapshot: [Job]) { count += 1 }
}
```

- [ ] **Step 3: Run the test and verify it fails**

Run: `swift test --filter QueueEngineTests`
Expected: FAIL — `cannot find 'QueueEngine' in scope`.

- [ ] **Step 4: Implement the engine**

`Sources/OxbowKit/Engine/QueueEngine.swift`:

```swift
import Foundation

/// Owns queue state and performs every side effect.
///
/// The scheduling rules live in `Scheduler` as pure functions, so this type is
/// mostly plumbing: admit, launch, fold the result back in, repeat.
public actor QueueEngine {

  public struct Configuration: Sendable {
    public var helperExecutable: URL
    public var ffmpegPath: URL
    public var workspace: Workspace
    public var store: QueueStore
    public var makeProcess: @Sendable () -> HelperProcessing

    public init(
      helperExecutable: URL,
      ffmpegPath: URL,
      workspace: Workspace,
      store: QueueStore,
      makeProcess: @escaping @Sendable () -> HelperProcessing)
    {
      self.helperExecutable = helperExecutable
      self.ffmpegPath = ffmpegPath
      self.workspace = workspace
      self.store = store
      self.makeProcess = makeProcess
    }
  }

  private struct RunningStep {
    let process: HelperProcessing
    let task: Task<Void, Never>
  }

  private let configuration: Configuration
  private var jobs: [Job] = []
  private var running: [StepID: RunningStep] = [:]
  private var observers: [UUID: AsyncStream<[Job]>.Continuation] = [:]
  private var saveTask: Task<Void, Never>?

  public init(configuration: Configuration) {
    self.configuration = configuration
  }

  // MARK: - Public surface

  public var currentJobs: [Job] { jobs }

  /// True when nothing is running and nothing further can be admitted.
  public var isIdle: Bool {
    running.isEmpty && Scheduler.admissible(jobs: jobs, running: []).isEmpty
  }

  public var snapshots: AsyncStream<[Job]> {
    AsyncStream { continuation in
      let id = UUID()
      observers[id] = continuation
      continuation.yield(jobs)
      continuation.onTermination = { [weak self] _ in
        Task { await self?.removeObserver(id) }
      }
    }
  }

  /// Sweeps the workspace, loads the queue, reconciles it, and starts work.
  ///
  /// The sweep is unconditional: nothing on disk can ever be resumed, so there
  /// is no case to reason about and no way for a power loss to leak disk.
  public func start() async throws {
    configuration.workspace.removeAll()

    let loaded = try configuration.store.load()
    jobs = Reconciler.reconcile(loaded) { FileManager.default.fileExists(atPath: $0.path) }

    tick()
  }

  public func enqueue(_ template: JobTemplate, title: String) {
    let job = template.makeJob(
      id: JobID(rawValue: UUID()),
      title: title,
      created: Date(),
      nextStepID: { StepID(rawValue: UUID()) })
    jobs.append(job)
    tick()
  }

  public func retry(step id: StepID) {
    Scheduler.retry(id, in: &jobs)
    tick()
  }

  public func cancel(step id: StepID) async {
    await running[id]?.process.cancel()
    Scheduler.cancel(id, in: &jobs)
    tick()
  }

  public func cancel(job id: JobID) async {
    guard let job = jobs.first(where: { $0.id == id }) else { return }
    for step in job.steps {
      await running[step.id]?.process.cancel()
    }
    Scheduler.cancel(job: id, in: &jobs)
    configuration.workspace.removeJob(id)
    tick()
  }

  /// Writes any pending state immediately. Call on app termination.
  public func flush() async {
    saveTask?.cancel()
    saveTask = nil
    try? configuration.store.save(jobs)
  }

  // MARK: - The single drive point

  /// Admits what it can and launches it. EVERY mutation ends here, so there is
  /// never a question of who was supposed to kick the queue.
  private func tick() {
    for id in Scheduler.admissible(jobs: jobs, running: Set(running.keys)) {
      launch(id)
    }
    publish()
    scheduleSave()
  }

  private func launch(_ id: StepID) {
    guard let location = locate(id) else { return }
    let job = jobs[location.job]
    let step = job.steps[location.step]

    let context: StepContext
    do {
      context = try makeContext(job: job, step: step)
    } catch {
      Scheduler.complete(id, with: .failed(StepFailure(
        kind: .launchFailed("\(error)"),
        summary: "Could not create a working directory.")), in: &jobs)
      tick()
      return
    }

    jobs[location.job].steps[location.step].status = .running

    let process = configuration.makeProcess()
    let launch = Launch(
      executable: configuration.helperExecutable,
      arguments: ArgumentBuilder.arguments(for: step.kind, context: context),
      workingDirectory: context.stepTempDirectory)

    let task = Task { [weak self] in
      await self?.execute(id, process: process, launch: launch, context: context)
    }
    running[id] = RunningStep(process: process, task: task)
  }

  private func execute(
    _ id: StepID,
    process: HelperProcessing,
    launch: Launch,
    context: StepContext)
    async
  {
    var result: RunResult
    do {
      result = try await process.run(launch) { [weak self] line in
        guard case .status(let progress) = line else { return }
        await self?.updateProgress(id, progress)
      }
    } catch {
      result = RunResult(status: .exited(-1), standardError: "\(error)")
    }

    finish(id, result: result, context: context)
  }

  private func updateProgress(_ id: StepID, _ progress: StepProgress) {
    guard let location = locate(id) else { return }
    jobs[location.job].steps[location.step].progress = progress
    publish()
  }

  private func finish(_ id: StepID, result: RunResult, context: StepContext) {
    running[id] = nil

    guard let location = locate(id) else { return }
    let job = jobs[location.job]
    let step = job.steps[location.step]

    let produced = FileManager.default.fileExists(atPath: context.outputFile.path)

    if let failure = FailureInterpreter.interpret(
      exitStatus: result.status,
      standardError: result.standardError,
      artifactExists: produced)
    {
      Scheduler.complete(id, with: .failed(failure), in: &jobs)
    } else {
      // The Swift parent moves the finished file out; the helper only ever
      // writes inside our workspace.
      let final = move(context.outputFile, toDestinationFor: step.kind) ?? context.outputFile
      Scheduler.complete(id, with: .succeeded(artifact: final), in: &jobs)
    }

    configuration.workspace.removeStep(job: job.id, step: id)

    if jobs[location.job].status == .done {
      configuration.workspace.removeJob(job.id)
    }

    tick()
  }

  // MARK: - Helpers

  private func removeObserver(_ id: UUID) {
    observers[id] = nil
  }

  private func publish() {
    for continuation in observers.values { continuation.yield(jobs) }
  }

  /// Debounced so a chatty render does not rewrite the queue file hundreds of
  /// times a second.
  private func scheduleSave() {
    saveTask?.cancel()
    saveTask = Task { [jobs, store = configuration.store] in
      try? await Task.sleep(for: .milliseconds(500))
      guard !Task.isCancelled else { return }
      try? store.save(jobs)
    }
  }

  private func locate(_ id: StepID) -> (job: Int, step: Int)? {
    for (jobIndex, job) in jobs.enumerated() {
      if let stepIndex = job.steps.firstIndex(where: { $0.id == id }) {
        return (jobIndex, stepIndex)
      }
    }
    return nil
  }

  private func makeContext(job: Job, step: Step) throws -> StepContext {
    let stepDirectory = try configuration.workspace.prepareStep(job: job.id, step: step.id)
    let artifacts = try configuration.workspace.prepareArtifacts(job: job.id)

    // The CLI infers download type from the output file extension.
    let name: String = switch step.kind {
    case .downloadVideo: "video.mp4"
    case .downloadClip: "clip.mp4"
    case .downloadChat(let request): "chat.\(request.format.rawValue)"
    case .renderChat: "render.mp4"
    }

    let input = step.dependsOn.flatMap { dependency in
      job.steps.first { $0.id == dependency }?.artifact
    }

    return StepContext(
      stepTempDirectory: stepDirectory,
      outputFile: artifacts.appending(path: name),
      ffmpegPath: configuration.ffmpegPath,
      inputArtifact: input)
  }

  /// Returns the final location, or nil when the step has no destination and
  /// its output stays in the workspace as an intermediate.
  private func move(_ file: URL, toDestinationFor kind: StepKind) -> URL? {
    let destination: URL? = switch kind {
    case .downloadVideo(let request): request.destination
    case .downloadClip(let request): request.destination
    case .downloadChat(let request): request.destination
    case .renderChat(let request): request.destination
    }
    guard let destination else { return nil }

    do {
      try FileManager.default.createDirectory(
        at: destination.deletingLastPathComponent(),
        withIntermediateDirectories: true)
      if FileManager.default.fileExists(atPath: destination.path) {
        _ = try FileManager.default.replaceItemAt(destination, withItemAt: file)
      } else {
        try FileManager.default.moveItem(at: file, to: destination)
      }
      return destination
    } catch {
      return nil
    }
  }
}
```

- [ ] **Step 5: Run the whole suite and verify it passes**

Run: `swift test`
Expected: PASS, all suites.

Two failures to expect and how to handle them:

**If it hangs on `runsDependentStepsInOrderAndCompletesTheJob`,** `isIdle` is
reporting false forever — check that `finish` always clears `running[id]`,
including on the early-return paths.

**If `snapshots` fails to compile under strict concurrency,** the likely cause is
the `AsyncStream` builder closure mutating `observers` from a `@Sendable`
context. Actors are reference types so mutating stored properties in a getter is
legal, but the escaping closure may still trip isolation checking. The fix is to
make it an explicit method rather than a computed property:

```swift
public func makeSnapshots() -> AsyncStream<[Job]> {
  let (stream, continuation) = AsyncStream<[Job]>.makeStream()
  let id = UUID()
  observers[id] = continuation
  continuation.yield(jobs)
  continuation.onTermination = { [weak self] _ in
    Task { await self?.removeObserver(id) }
  }
  return stream
}
```

Update the test's `await engine.snapshots` to `await engine.makeSnapshots()` if
you take this route. Do not reach for `nonisolated(unsafe)` to silence it.

- [ ] **Step 6: Commit**

```bash
git add Sources/OxbowKit/Engine Sources/OxbowKit/Process/HelperProcessing.swift Tests/OxbowKitTests/QueueEngineTests.swift
git commit -m "feat(engine): add QueueEngine

The one actor and the only place side effects happen. Every mutation ends at
tick(), so nothing else decides when work starts.

Verifies the artifact rather than trusting the exit code, moves finished files
out of the workspace itself, deletes each step directory however the process
died, and debounces the queue file so a chatty render does not rewrite it
hundreds of times a second."
```

---

## Self-review notes

**Spec coverage.** §1 facts are enforced by Tasks 1–4 (§1.1, §1.2), 9 (§1.6, §1.7),
12 (§1.3), 10–11 (§1.4), 13 (§1.5). §2 → Tasks 5–6. §3 → Tasks 7–8, 14.
§4 → Tasks 9–11. §5 → Tasks 12–13. §6 → Task 13. §7 → the tests throughout.

**Deliberately deferred, and not silently.** Two things from spec §3 are not in
any task above and must not be forgotten:

- **Progress coalescing to ~10 Hz.** `updateProgress` currently publishes on
  every status line, which for a render is ~400 publishes. Correct but wasteful.
  Add it when a real UI exists to measure against — premature otherwise, since
  the right interval depends on what the view does with a snapshot.
- **`@MainActor @Observable` view-model projection.** Belongs with the first
  SwiftUI view, not here; `snapshots` is the seam it will consume.

**Not covered because v1 excludes it** (spec §8): auto-retry, cache management,
resume, priorities, reordering, notifications.
