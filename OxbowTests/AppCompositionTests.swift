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
