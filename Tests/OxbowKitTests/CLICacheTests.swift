import Foundation
import Testing

@testable import OxbowKit

@Suite("CLI cache")
struct CLICacheTests {

  private struct Harness {
    let cache: CLICache
    let workspace: Workspace
    let base: URL
  }

  private func makeHarness() throws -> Harness {
    let base = URL(filePath: NSTemporaryDirectory()).appending(path: "oxbow-cache-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    return Harness(
      cache: CLICache(root: base.appending(path: "cli-cache")),
      workspace: Workspace(root: base.appending(path: "workspace")),
      base: base)
  }

  private func cleanUp(_ h: Harness) {
    try? FileManager.default.removeItem(at: h.base)
  }

  private func prepareStep(_ h: Harness) throws -> (job: JobID, step: StepID, directory: URL) {
    let job = JobID(rawValue: UUID())
    let step = StepID(rawValue: UUID())
    let directory = try h.workspace.prepareStep(job: job, step: step)
    return (job, step, directory)
  }

  /// Where the CLI looks for a kind of asset, given `--temp-path directory`.
  private func cliFolder(_ directory: URL, _ kind: String) -> URL {
    directory.appending(path: "TwitchDownloader").appending(path: kind)
  }

  private func isSymlink(_ url: URL) -> Bool {
    (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) != nil
  }

  @Test func linksEverySharedKindIntoTheCache() throws {
    let h = try makeHarness()
    defer { cleanUp(h) }
    let step = try prepareStep(h)

    h.cache.link(into: step.directory)

    for kind in CLICache.sharedKinds {
      let link = cliFolder(step.directory, kind)
      #expect(isSymlink(link), "\(kind) should be a link")
      let target = try FileManager.default.destinationOfSymbolicLink(atPath: link.path)
      #expect(URL(filePath: target).standardizedFileURL == h.cache.root.appending(path: kind).standardizedFileURL)
    }
  }

  /// Cheermotes key on a node id not proven unique across channels, so they stay per step.
  /// docs/design/native-chat-render.md §3.2.
  @Test func leavesCheermotesPerStep() throws {
    let h = try makeHarness()
    defer { cleanUp(h) }
    let step = try prepareStep(h)

    h.cache.link(into: step.directory)

    #expect(!CLICache.sharedKinds.contains("bits"))
    #expect(!FileManager.default.fileExists(atPath: cliFolder(step.directory, "bits").path))
  }

  @Test func twoStepsSeeTheSameCachedFile() throws {
    let h = try makeHarness()
    defer { cleanUp(h) }
    let first = try prepareStep(h)
    let second = try prepareStep(h)
    h.cache.link(into: first.directory)
    h.cache.link(into: second.directory)

    let written = cliFolder(first.directory, "stv").appending(path: "01ABC_2.webp")
    try Data([1, 2, 3]).write(to: written)

    let seen = cliFolder(second.directory, "stv").appending(path: "01ABC_2.webp")
    #expect(try Data(contentsOf: seen) == Data([1, 2, 3]))
  }

  /// The whole design rests on this: the workspace unlinks symlinks as leaves, so removing a job
  /// cannot reach through a link and empty the cache every other job shares.
  @Test func removingAJobLeavesTheSharedCacheIntact() throws {
    let h = try makeHarness()
    defer { cleanUp(h) }
    let step = try prepareStep(h)
    h.cache.link(into: step.directory)
    try Data([9]).write(to: cliFolder(step.directory, "emotes").appending(path: "120232_2.png"))

    let failures = h.workspace.removeJob(step.job)

    #expect(failures.isEmpty)
    #expect(!FileManager.default.fileExists(atPath: step.directory.path))
    #expect(FileManager.default.fileExists(
      atPath: h.cache.root.appending(path: "emotes").appending(path: "120232_2.png").path))
  }

  /// A step retried in a directory that already holds a real folder keeps using that folder. A
  /// cache is an optimisation and must never fail a job.
  @Test func leavesAnExistingRealFolderAloneAndDoesNotThrow() throws {
    let h = try makeHarness()
    defer { cleanUp(h) }
    let step = try prepareStep(h)
    let existing = cliFolder(step.directory, "stv")
    try FileManager.default.createDirectory(at: existing, withIntermediateDirectories: true)
    try Data([7]).write(to: existing.appending(path: "kept.webp"))

    h.cache.link(into: step.directory)

    #expect(!isSymlink(existing))
    #expect(FileManager.default.fileExists(atPath: existing.appending(path: "kept.webp").path))
    #expect(isSymlink(cliFolder(step.directory, "bttv")))
  }

  @Test func linkingTwiceIntoTheSameStepIsHarmless() throws {
    let h = try makeHarness()
    defer { cleanUp(h) }
    let step = try prepareStep(h)

    h.cache.link(into: step.directory)
    h.cache.link(into: step.directory)

    for kind in CLICache.sharedKinds {
      #expect(isSymlink(cliFolder(step.directory, kind)))
    }
  }

  /// Only the verbs that fetch emotes, badges and emoji share the cache; a video download's temp
  /// directory holds its own segments and nothing else.
  @Test func onlyChatAndRenderStepsAreLinked() throws {
    let h = try makeHarness()
    defer { cleanUp(h) }
    let journal = TeardownJournal(workspace: h.workspace)
    let builder = StepContextBuilder(
      workspace: h.workspace,
      ffmpegPath: URL(filePath: "/usr/bin/false"),
      ledger: ResumeLedger(workspace: h.workspace, journal: journal),
      cliCache: h.cache)

    let chat = Step(id: StepID(rawValue: UUID()), kind: .downloadChat(ChatRequest(videoID: "1", format: .json)))
    let render = Step(id: StepID(rawValue: UUID()), kind: .renderChat(RenderRequest()), dependsOn: [chat.id])
    let video = Step(id: StepID(rawValue: UUID()), kind: .downloadVideo(VideoRequest(videoID: "1", quality: "best")))
    var chatDone = chat
    chatDone.status = .done
    chatDone.artifact = h.base.appending(path: "chat.json")
    let job = Job(
      id: JobID(rawValue: UUID()), created: Date(), title: "t", steps: [chatDone, render, video])

    for step in [chat, render] {
      let context = try builder.make(job: job, step: step)
      #expect(isSymlink(cliFolder(context.stepTempDirectory, "stv")))
    }
    let videoContext = try builder.make(job: job, step: video)
    #expect(!FileManager.default.fileExists(atPath: cliFolder(videoContext.stepTempDirectory, "stv").path))
  }

  @Test func trimEmptiesACacheOverTheLimit() throws {
    let h = try makeHarness()
    defer { cleanUp(h) }
    let folder = h.cache.root.appending(path: "stv")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try Data(count: 64 * 1024).write(to: folder.appending(path: "a.webp"))

    h.cache.trim(toAtMost: 16 * 1024)

    #expect(!FileManager.default.fileExists(atPath: folder.appending(path: "a.webp").path))
  }

  @Test func trimLeavesACacheUnderTheLimit() throws {
    let h = try makeHarness()
    defer { cleanUp(h) }
    let folder = h.cache.root.appending(path: "stv")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    // Sizes are allocated, not logical — a 512-byte file occupies a whole block — so leave room.
    try Data(count: 512).write(to: folder.appending(path: "a.webp"))

    h.cache.trim(toAtMost: 1024 * 1024)

    #expect(FileManager.default.fileExists(atPath: folder.appending(path: "a.webp").path))
  }

  @Test func trimOfACacheThatWasNeverCreatedDoesNothing() throws {
    let h = try makeHarness()
    defer { cleanUp(h) }

    h.cache.trim(toAtMost: 0)

    #expect(!FileManager.default.fileExists(atPath: h.cache.root.path))
  }
}
