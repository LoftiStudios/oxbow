import Foundation

/// The parts of the About window that come from the built bundle rather than
/// from source.
///
/// Separated from the view so the legally load-bearing bits — the version
/// string a bug report quotes, the upstream commit a shipped DMG is traceable
/// to, whether the LGPL text is actually in the bundle — are ordinary values
/// that can be asserted against without rendering anything.
///
/// The initialiser takes a dictionary and a lookup rather than a `Bundle` for
/// the same reason: a test can describe a build with no helper, or no licence
/// text, without needing a bundle in that state to exist on disk.
///
/// `nonisolated` for the reason `JobPresentation` is: the target defaults new
/// declarations to `@MainActor`, but this is a plain value derived from a
/// dictionary, and `OxbowTests` has no actor default of its own and calls it
/// synchronously.
nonisolated struct AboutInfo {

  /// Written by `scripts/stamp-version.sh` at build time. Absent by design in
  /// a build that has no helper or no FFmpeg embedded — the UI-only fast path
  /// CONTRIBUTING.md promises — so both are optional all the way to the view.
  private enum Key {
    static let helperVersion = "OXHelperVersion"
    static let ffmpegVersion = "OXFFmpegVersion"
  }

  /// Staged into `Contents/Resources` by `scripts/embed-helpers.sh`. Renaming
  /// either here means renaming it there; the About window's buttons are the
  /// only reason they are in the bundle at all (docs/ffmpeg.md §6).
  private enum Licence {
    static let ffmpegLicense = "COPYING.LGPLv2.1"
    static let ffmpegSourceRecord = "FFMPEG-SOURCE.txt"
  }

  let applicationName: String
  /// Pre-composed rather than exposing the two halves, because every caller
  /// wants the same sentence and the interesting behaviour is what happens
  /// when a half is missing.
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
      // A nil extension matches the whole filename, which is what we want:
      // splitting `COPYING.LGPLv2.1` into a stem and an extension would be
      // guessing at where the version number stops.
      bundle.url(forResource: name, withExtension: nil)
    }
  }

  private static func versionLine(shortVersion: String?, build: String?) -> String {
    // No marketing version means a malformed bundle. Saying so beats
    // rendering "Version  (73)" and leaving the reader to work it out.
    guard let shortVersion else { return "Unknown version" }
    // No build number is normal: an export with no git history keeps the
    // CURRENT_PROJECT_VERSION fallback rather than gaining a fake count, and
    // a fallback is not worth showing.
    guard let build else { return "Version \(shortVersion)" }
    return "Version \(shortVersion) (\(build))"
  }
}

/// One third-party attribution shown in the About window.
///
/// MIT requires the copyright notice travel with the binary and LGPL 2.1+
/// requires the same for FFmpeg, so this list is a licence obligation rather
/// than a courtesy. It mirrors the "Third Party Credits" section of
/// `README.md`; keep the two in step.
///
/// Licences are named only for the two executables we actually bundle, whose
/// terms `README.md` and `docs/ffmpeg.md` state directly. Everything else
/// reaches Oxbow through the helper, and upstream's `THIRD-PARTY-LICENSES.txt`
/// — linked at the end of this list — is the authority on those terms. Naming
/// them here would be restating someone else's licence from memory.
///
/// `nonisolated` for the same reason as `AboutInfo`.
nonisolated struct Credit: Identifiable {
  var id: String { name }

  let name: String
  let detail: String
  /// Stored as a string and parsed on demand rather than force-unwrapped into
  /// a `URL` at declaration, so a typo in an attribution link is a test
  /// failure instead of a crash on opening the About window.
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

/// One bundled licence file, held in memory so the About window can show it.
///
/// Showing the text rather than handing the file to `NSWorkspace` is not a
/// stylistic choice. `COPYING.LGPLv2.1` has the extension `1`, which macOS
/// cannot classify — `mdls` reports the dynamic UTI `dyn.ah62d4rv4ge8xc`,
/// meaning no application is registered for it. Asking the system to open it
/// produces a "no application set to open the document" dead end, and the one
/// artifact the LGPL actually requires we make available would be the one the
/// user could not read.
///
/// `nonisolated` for the same reason as `AboutInfo`.
nonisolated struct LicenceDocument: Identifiable {
  var id: String { title }

  let title: String
  let text: String

  init(title: String, data: Data) {
    self.title = title
    // Latin-1 has no invalid byte sequences, so this always yields something.
    // Both staged files are ASCII today; the fallback exists so that stops
    // being load-bearing.
    text = String(data: data, encoding: .utf8)
      ?? String(data: data, encoding: .isoLatin1)
      ?? ""
  }

  init?(title: String, url: URL?) {
    guard let url, let data = try? Data(contentsOf: url) else { return nil }
    self.init(title: title, data: data)
  }
}
