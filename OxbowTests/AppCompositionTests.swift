import Foundation
import Testing
import OxbowKit
@testable import Oxbow

@Suite("App composition")
struct AppCompositionTests {

  private let executable = URL(filePath: "/Apps/Oxbow.app/Contents/MacOS/Oxbow")
  private let support = URL(filePath: "/Users/me/Library/Application Support/studio.lofti.Oxbow")

  private func resolve(existing: Set<String>) -> AppComposition.Result {
    AppComposition.resolve(
      bundleExecutable: executable,
      supportDirectory: support,
      fileExists: { existing.contains($0.path) })
  }

  private var bothPresent: Set<String> {
    ["/Apps/Oxbow.app/Contents/MacOS/helper/TwitchDownloaderCLI",
     "/Apps/Oxbow.app/Contents/MacOS/ffmpeg"]
  }

  @Test func resolvesHelperAndFFmpegBesideTheExecutable() throws {
    guard case .ready(let configuration) = resolve(existing: bothPresent) else {
      Issue.record("expected .ready")
      return
    }

    #expect(configuration.helperExecutable.path == "/Apps/Oxbow.app/Contents/MacOS/helper/TwitchDownloaderCLI")
    #expect(configuration.ffmpegPath.path == "/Apps/Oxbow.app/Contents/MacOS/ffmpeg")
  }

  @Test func putsTheWorkspaceUnderApplicationSupportNotTheBundle() throws {
    guard case .ready(let configuration) = resolve(existing: bothPresent) else {
      Issue.record("expected .ready")
      return
    }

    // A quarantined app runs from a read-only App Translocation mount, so
    // anything written beside the bundle fails on first launch.
    #expect(configuration.workspace.root.path.hasPrefix(support.path))
    #expect(!configuration.workspace.root.path.contains(".app/"))
    #expect(configuration.store.fileURL.path.hasPrefix(support.path))
  }

  // MARK: - User session

  /// The test bundle is hosted by the app, so running this suite launches
  /// `OxbowApp` — and with it the launch-time update check, which made a live
  /// GitHub request and wrote the developer's real `.standard` preferences on
  /// every `xcodebuild test`, CI included. It passed unnoticed because the
  /// automatic path swallows its own failures.
  ///
  /// Measured before the guard existed: with no tests running the key stayed
  /// absent over 15s; one test run later it was there.
  ///
  /// This assertion holds only while the guard reads a variable XCTest really
  /// sets — misspell the key and it silently becomes false.
  @Test func aTestHostIsNotAUserSession() {
    #expect(!AppComposition.isUserSession)
  }

  @Test func reportsAMissingHelper() {
    guard case .helperMissing(let message) = resolve(existing: ["/Apps/Oxbow.app/Contents/MacOS/ffmpeg"]) else {
      Issue.record("expected .helperMissing")
      return
    }
    #expect(message.contains("dotnet publish"))
  }

  @Test func reportsMissingFFmpeg() {
    guard case .helperMissing(let message) = resolve(existing: ["/Apps/Oxbow.app/Contents/MacOS/helper/TwitchDownloaderCLI"]) else {
      Issue.record("expected .helperMissing")
      return
    }
    #expect(message.contains("build-ffmpeg.sh"))
  }
}
