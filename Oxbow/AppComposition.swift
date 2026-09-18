import Foundation
import OxbowKit

/// Resolves helper and state paths. `nonisolated` allows callers outside the app's default main
/// actor.
nonisolated enum AppComposition {

  enum Result {
    case ready(QueueEngine.Configuration)
    /// UI-only builds may omit helpers; `embed-helpers.sh` warns but allows the build.
    case helperMissing(String)
  }

  /// False in the XCTest host process. Gate live services here to avoid network requests and
  /// writes to the user's preferences during tests.
  static var isUserSession: Bool {
    ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil
  }

  static func resolve(
    bundleExecutable: URL,
    supportDirectory: URL,
    fileExists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) })
    -> Result
  {
    // Helpers live in the bundle's code directory; see docs/signing.md §2.
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

  /// Keep persistent state outside disposable job workspaces swept at startup.
  static func watchStoreURL(supportDirectory: URL) -> URL {
    supportDirectory.appending(path: "watches.json")
  }

  static func videoRecordURL(supportDirectory: URL) -> URL {
    supportDirectory.appending(path: "videos.json")
  }

  /// Store raw info payloads separately to keep videos.json small; see
  /// docs/design/video-record.md §3.3.
  static func payloadDirectory(supportDirectory: URL) -> URL {
    supportDirectory.appending(path: "payloads")
  }

  /// Refetchable images live outside the workspace so they survive its startup sweep.
  static func imageStoreURL(supportDirectory: URL) -> URL {
    supportDirectory.appending(path: "images")
  }

  /// Creates ~/Library/Application Support/studio.lofti.Oxbow. DEBUG builds may override it
  /// with OXBOW_FIXTURE_DIR for screenshot fixtures.
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
