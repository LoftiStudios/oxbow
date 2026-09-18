import Foundation

/// Bundle versions and licence resources. Injected values support builds with missing helpers
/// or licences. `nonisolated` permits synchronous use outside the app's default main actor.
nonisolated struct AboutInfo {

  /// Written by `scripts/stamp-version.sh`; absent when the corresponding helper is not
  /// embedded.
  private enum Key {
    static let helperVersion = "OXHelperVersion"
    static let ffmpegVersion = "OXFFmpegVersion"
  }

  /// Staged into Resources by `scripts/embed-helpers.sh`; keep these filenames in sync.
  private enum Licence {
    static let ffmpegLicense = "COPYING.LGPLv2.1"
    static let ffmpegSourceRecord = "FFMPEG-SOURCE.txt"
  }

  let applicationName: String
  let versionLine: String
  let copyright: String?
  let helperVersion: String?
  let ffmpegVersion: String?
  let ffmpegLicense: URL?
  let ffmpegSourceRecord: URL?

  init(infoDictionary: [String: Any], resource: (String) -> URL?) {
    applicationName = infoDictionary["CFBundleName"] as? String ?? "Oxbow"
    versionLine = Self.versionLine(
      shortVersion: infoDictionary["CFBundleShortVersionString"] as? String,
      build: infoDictionary["CFBundleVersion"] as? String)
    copyright = infoDictionary["NSHumanReadableCopyright"] as? String
    helperVersion = infoDictionary[Key.helperVersion] as? String
    ffmpegVersion = infoDictionary[Key.ffmpegVersion] as? String
    ffmpegLicense = resource(Licence.ffmpegLicense)
    ffmpegSourceRecord = resource(Licence.ffmpegSourceRecord)
  }

  static var main: AboutInfo {
    let bundle = Bundle.main
    return AboutInfo(infoDictionary: bundle.infoDictionary ?? [:]) { name in
      // Match the complete filename, including the licence version suffix.
      bundle.url(forResource: name, withExtension: nil)
    }
  }

  private static func versionLine(shortVersion: String?, build: String?) -> String {
    guard let shortVersion else { return "Unknown version" }
    // An export without git history may have no build number.
    guard let build else { return "Version \(shortVersion)" }
    return "Version \(shortVersion) (\(build))"
  }
}

/// Required third-party notices; keep in sync with README.md. The helper's transitive licences
/// are listed in upstream's THIRD-PARTY-LICENSES.txt.
nonisolated struct Credit: Identifiable {
  var id: String { name }

  let name: String
  let detail: String
  /// Parse on demand so an invalid attribution URL cannot crash the About window.
  let urlString: String

  var url: URL? { URL(string: urlString) }

  static let all: [Credit] = [
    Credit(
      name: "TwitchDownloaderCLI",
      detail: "© lay295 and contributors, MIT. Performs downloads and chat rendering.",
      urlString: "https://github.com/lay295/TwitchDownloader"),
    Credit(
      name: "FFmpeg",
      detail: "© The FFmpeg developers, LGPL 2.1+. Bundled unmodified; encodes and finalises video.",
      urlString: "https://ffmpeg.org/"),
    Credit(
      name: ".NET",
      detail: "© Microsoft Corporation. The bundled helper is a self-contained .NET application.",
      urlString: "https://github.com/dotnet/runtime"),
    Credit(
      name: "SkiaSharp and HarfBuzzSharp",
      detail: "© Microsoft Corporation. Draw chat renders, by way of TwitchDownloaderCLI.",
      urlString: "https://github.com/mono/SkiaSharp"),
    Credit(
      name: "Noto Color Emoji",
      detail: "© Google and contributors. May supply emoji in chat renders.",
      urlString: "https://github.com/googlefonts/noto-emoji"),
    Credit(
      name: "Twemoji",
      detail: "© Twitter and contributors. May supply emoji in chat renders.",
      urlString: "https://github.com/jdecked/twemoji"),
    Credit(
      name: "Full third-party licence list",
      detail: "Every library reaching Oxbow through the bundled helper.",
      urlString:
        "https://github.com/lay295/TwitchDownloader/blob/master/TwitchDownloaderCore/Resources/THIRD-PARTY-LICENSES.txt"),
  ]
}

/// Bundled licence text displayed in-app: macOS has no registered application for the `.1`
/// extension of COPYING.LGPLv2.1.
nonisolated struct LicenceDocument: Identifiable {
  var id: String { title }

  let title: String
  let text: String

  init(title: String, data: Data) {
    self.title = title
    // Latin-1 accepts any byte sequence if UTF-8 decoding fails.
    text = String(data: data, encoding: .utf8)
      ?? String(data: data, encoding: .isoLatin1)
      ?? ""
  }

  init?(title: String, url: URL?) {
    guard let url, let data = try? Data(contentsOf: url) else { return nil }
    self.init(title: title, data: data)
  }
}
