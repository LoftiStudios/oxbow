#if DEBUG
import AppKit
import Foundation
import OxbowKit
import SwiftUI

/// DEBUG-only screenshot state redirected through AppComposition.defaultSupportDirectory().
/// Fixtures use the app's persisted format with fictional identities; keep layout coordinates
/// out of the harness.
nonisolated enum ScreenshotFixture {

  /// Set to a directory that will stand in for
  /// `~/Library/Application Support/studio.lofti.Oxbow`.
  static let environmentKey = "OXBOW_FIXTURE_DIR"

  /// Treat an empty override as unset, not as the filesystem root.
  static var directory: URL? {
    guard
      let path = ProcessInfo.processInfo.environment[environmentKey],
      !path.isEmpty
    else { return nil }
    return URL(filePath: path, directoryHint: .isDirectory)
  }

  /// Title substring selecting a row to expand; expansion is view state rather than persisted
  /// queue data.
  static let expandKey = "OXBOW_FIXTURE_EXPAND"

  /// Enable expansion only during fixture runs.
  static func expandsJob(titled title: String) -> Bool {
    guard directory != nil else { return false }
    guard
      let wanted = ProcessInfo.processInfo.environment[expandKey],
      !wanted.isEmpty
    else { return false }
    return title.contains(wanted)
  }

  /// Fixture content size as WIDTHxHEIGHT in points. Override restored AppKit frames, which
  /// live outside the redirected support directory.
  static var windowSize: CGSize? {
    guard directory != nil else { return nil }
    guard let raw = ProcessInfo.processInfo.environment["OXBOW_FIXTURE_SIZE"] else { return nil }
    let parts = raw.lowercased().split(separator: "x")
    guard
      parts.count == 2,
      let width = Double(parts[0]), let height = Double(parts[1]),
      width > 0, height > 0
    else { return nil }
    return CGSize(width: width, height: height)
  }
}

/// Fixture metadata DTO avoids adding screenshot-only Codable conformance to VideoInfo.
struct ScreenshotVideoInfo: Decodable {
  struct Quality: Decodable {
    var name: String
    var resolution: String
    var bitsPerSecond: Int
  }

  var streamer: String
  var title: String
  /// Absolute ISO 8601 date keeps metadata consistent with titles in the queue fixture.
  var createdAt: String
  var durationSeconds: Double
  var qualities: [Quality]
  /// Resolve against the fixture HTTP server; image loading requires HTTP status 200 and
  /// rejects file URLs.
  var thumbnailPaths: [String]

  func resolved(thumbnailBase: URL?) -> VideoInfo {
    VideoInfo(
      streamer: streamer,
      title: title,
      createdAt: ISO8601DateFormatter().date(from: createdAt) ?? .now,
      duration: .seconds(durationSeconds),
      qualities: qualities.map {
        StreamQuality(name: $0.name, resolution: $0.resolution, bitsPerSecond: $0.bitsPerSecond)
      },
      thumbnailURLs: thumbnailBase.map { base in
        thumbnailPaths.map { base.appending(path: $0) }
      } ?? [])
  }
}

/// Deliberately not `nonisolated`, unlike the extensions on the other pure helpers: `videoInfo`
/// below decodes `ScreenshotVideoInfo` and calls `resolved(thumbnailBase:)`, both main-actor
/// isolated, so marking this extension nonisolated does not compile.
extension ScreenshotFixture {

  /// The link the intake opens with, seeded as though it had been pasted.
  static var link: String? {
    guard directory != nil else { return nil }
    let value = ProcessInfo.processInfo.environment["OXBOW_FIXTURE_LINK"]
    return (value?.isEmpty == false) ? value : nil
  }

  /// Fixture trim expansion is transient model state, not a saved preference.
  static var opensTrim: Bool {
    directory != nil && ProcessInfo.processInfo.environment["OXBOW_FIXTURE_TRIM"] == "1"
  }

  /// Where the script is serving `fixture/thumbnail.jpg`, e.g.
  /// `http://127.0.0.1:8731`.
  static var thumbnailBase: URL? {
    guard directory != nil else { return nil }
    guard let raw = ProcessInfo.processInfo.environment["OXBOW_FIXTURE_THUMBS"], !raw.isEmpty
    else { return nil }
    return URL(string: raw)
  }

  /// Return videoinfo-<id>.json, falling back to videoinfo.json. Per-video answers keep
  /// inspector cards consistent with selected queue rows.
  static func videoInfo(for id: String) -> VideoInfo? {
    guard let directory else { return nil }
    let candidates = ["videoinfo-\(id).json", "videoinfo.json"]
    for name in candidates {
      guard
        let data = try? Data(contentsOf: directory.appending(path: name)),
        let decoded = try? JSONDecoder().decode(ScreenshotVideoInfo.self, from: data)
      else { continue }
      return decoded.resolved(thumbnailBase: thumbnailBase)
    }
    return nil
  }
}

/// Open intake through its scene id when the fixture supplies a link, avoiding coordinate-based
/// clicks.
struct ScreenshotIntakeOpener: View {
  @Environment(\.openWindow) private var openWindow
  let windowID: String

  var body: some View {
    Color.clear
      .frame(width: 0, height: 0)
      .onAppear {
        guard ScreenshotFixture.link != nil else { return }
        openWindow(id: windowID)
        // ScreenshotWindowFocus restores queue focus after intake opens.
      }
  }
}

/// Restore queue key status after intake appears. The harness launches with open -n for
/// foreground activation; use the hosting window rather than title matching.
struct ScreenshotWindowFocus: NSViewRepresentable {
  func makeNSView(context: Context) -> NSView {
    let view = NSView(frame: .zero)
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
      NSApp.activate()
      view.window?.makeKeyAndOrderFront(nil)
    }
    return view
  }

  func updateNSView(_ nsView: NSView, context: Context) {}
}

/// Apply fixture sizing after window attachment to override restored frames.
struct ScreenshotWindowSizer: NSViewRepresentable {
  func makeNSView(context: Context) -> NSView {
    let view = NSView(frame: .zero)
    DispatchQueue.main.async {
      guard let window = view.window, let size = ScreenshotFixture.windowSize else { return }
      window.setContentSize(size)
      window.center()
    }
    return view
  }

  func updateNSView(_ nsView: NSView, context: Context) {}
}
#endif
