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
  static func defaultSupportDirectory() throws -> URL {
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
