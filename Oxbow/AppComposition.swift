import Foundation
import OxbowKit

/// Resolves where the helper, FFmpeg, and our own state live, or says
/// precisely why it cannot.
///
/// `nonisolated`: the target defaults new declarations to `@MainActor`, but
/// this is pure path resolution with no UI dependency — `resolve` only reads
/// its arguments, and `defaultSupportDirectory()` only touches `Bundle.main`
/// and `FileManager`, neither of which is actor-isolated. Both should be free
/// to run off the main actor, and `OxbowTests` (which has no actor default of
/// its own) calls `resolve` synchronously, which requires it.
nonisolated enum AppComposition {

  enum Result {
    case ready(QueueEngine.Configuration)
    /// A payload is absent. Not defensive programming: `embed-helpers.sh`
    /// deliberately warns and continues when build/helper is missing, so
    /// contributors doing UI work need no .NET or FFmpeg toolchain. Those
    /// builds run and simply cannot download.
    case helperMissing(String)
  }

  /// Whether this process is a person using Oxbow, as opposed to the app
  /// being launched only to host a unit-test bundle.
  ///
  /// `OxbowTests` runs inside this app, so `xcodebuild test` starts
  /// `OxbowApp` for real — scenes, `.task` modifiers and all. Anything the
  /// launch path reaches for, a test run reaches for too. That made every
  /// test run, on every developer machine and on every CI run, perform a live
  /// unauthenticated request to api.github.com and write the real
  /// `studio.lofti.Oxbow` preferences. Nothing failed, because the automatic
  /// update check is silent about its own errors by design — which is exactly
  /// why it went unnoticed.
  ///
  /// `XCTestConfigurationFilePath` is set by XCTest in the host process and
  /// by nothing else, so it distinguishes the two without the app having to
  /// know what a test is beyond "not a user".
  static var isUserSession: Bool {
    ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil
  }

  static func resolve(
    bundleExecutable: URL,
    supportDirectory: URL,
    fileExists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) })
    -> Result
  {
    // Contents/MacOS - the bundle's code location, and the only place
    // executable code may legally live (docs/signing.md section 2).
    let macOS = bundleExecutable.deletingLastPathComponent()
    let helper = macOS.appending(path: "helper/TwitchDownloaderCLI")
    let ffmpeg = macOS.appending(path: "ffmpeg")

    guard fileExists(helper) else {
      return .helperMissing("""
        The TwitchDownloaderCLI helper is not embedded in this build. \
        Build it with the dotnet publish command in docs/development.md, \
        then build the app again.
        """)
    }
    guard fileExists(ffmpeg) else {
      return .helperMissing("""
        FFmpeg is not embedded in this build. Build it with \
        ./scripts/build-ffmpeg.sh, then build the app again.
        """)
    }

    return .ready(QueueEngine.Configuration(
      helperExecutable: helper,
      ffmpegPath: ffmpeg,
      workspace: Workspace(root: supportDirectory.appending(path: "workspace")),
      store: QueueStore(fileURL: supportDirectory.appending(path: "queue.json")),
      makeProcess: { HelperProcess() }))
  }

  /// `~/Library/Application Support/studio.lofti.Oxbow`, created if absent.
  ///
  /// In a DEBUG build `OXBOW_FIXTURE_DIR` overrides it, which is what lets
  /// `scripts/screenshots.sh` launch the real app against a checked-in queue
  /// instead of the developer's own. See `ScreenshotFixture`. This is the one
  /// place the app decides where its state lives, so the redirect needs no
  /// cooperation from any view.
  static func defaultSupportDirectory() throws -> URL {
    #if DEBUG
    if let fixture = ScreenshotFixture.directory {
      try FileManager.default.createDirectory(at: fixture, withIntermediateDirectories: true)
      return fixture
    }
    #endif

    let base = try FileManager.default.url(
      for: .applicationSupportDirectory,
      in: .userDomainMask,
      appropriateFor: nil,
      create: true)
    let directory = base.appending(path: Bundle.main.bundleIdentifier ?? "studio.lofti.Oxbow")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
  }
}
