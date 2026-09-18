import Foundation
import Testing
@testable import Oxbow

@Suite("About info")
struct AboutInfoTests {

  /// Complete stamped bundle fixture; tests remove individual keys to model missing build
  /// components.
  private func info(
    name: String? = "Oxbow",
    shortVersion: String? = "0.1.0",
    build: String? = "73",
    copyright: String? = "© 2026 Lofti Studios LLC. MIT licensed.",
    helper: String? = "1.56.5+d4122d80214b08b3c7078003aae43088e601a435",
    ffmpeg: String? = "8.1.2"
  ) -> [String: Any] {
    var dictionary: [String: Any] = [:]
    dictionary["CFBundleName"] = name
    dictionary["CFBundleShortVersionString"] = shortVersion
    dictionary["CFBundleVersion"] = build
    dictionary["NSHumanReadableCopyright"] = copyright
    dictionary["OXHelperVersion"] = helper
    dictionary["OXFFmpegVersion"] = ffmpeg
    return dictionary.compactMapValues { $0 }
  }

  private let noResources: (String) -> URL? = { _ in nil }

  // MARK: - Version line

  @Test func versionLineCombinesSemverAndBuildNumber() {
    let about = AboutInfo(infoDictionary: info(), resource: noResources)
    #expect(about.versionLine == "Version 0.1.0 (73)")
  }

  /// Without git history, omit the unavailable build number and its punctuation.
  @Test func versionLineOmitsAnAbsentBuildNumber() {
    let about = AboutInfo(infoDictionary: info(build: nil), resource: noResources)
    #expect(about.versionLine == "Version 0.1.0")
  }

  /// Missing marketing version must not leave empty version punctuation.
  @Test func versionLineReportsAnUnknownVersionWithoutASemver() {
    let about = AboutInfo(infoDictionary: info(shortVersion: nil), resource: noResources)
    #expect(about.versionLine == "Unknown version")
  }

  // MARK: - Identity

  @Test func applicationNameComesFromTheBundle() {
    let about = AboutInfo(infoDictionary: info(), resource: noResources)
    #expect(about.applicationName == "Oxbow")
  }

  @Test func applicationNameFallsBackWhenTheBundleDoesNotNameItself() {
    let about = AboutInfo(infoDictionary: info(name: nil), resource: noResources)
    #expect(about.applicationName == "Oxbow")
  }

  @Test func copyrightComesFromTheBundle() {
    let about = AboutInfo(infoDictionary: info(), resource: noResources)
    #expect(about.copyright == "© 2026 Lofti Studios LLC. MIT licensed.")
  }

  // MARK: - Bundled components

  /// The string that makes a shipped build traceable to an exact upstream
  /// commit (docs/development.md, "Upstream").
  @Test func helperVersionReadsTheStampedKey() {
    let about = AboutInfo(infoDictionary: info(), resource: noResources)
    #expect(about.helperVersion == "1.56.5+d4122d80214b08b3c7078003aae43088e601a435")
  }

  /// UI-only builds omit the helper stamp and must report it absent.
  @Test func helperVersionIsNilWhenTheHelperIsNotEmbedded() {
    let about = AboutInfo(infoDictionary: info(helper: nil), resource: noResources)
    #expect(about.helperVersion == nil)
  }

  @Test func ffmpegVersionReadsTheStampedKey() {
    let about = AboutInfo(infoDictionary: info(), resource: noResources)
    #expect(about.ffmpegVersion == "8.1.2")
  }

  @Test func ffmpegVersionIsNilWhenFFmpegIsNotEmbedded() {
    let about = AboutInfo(infoDictionary: info(ffmpeg: nil), resource: noResources)
    #expect(about.ffmpegVersion == nil)
  }

  // MARK: - LGPL compliance files

  /// `embed-helpers.sh` stages both into `Contents/Resources`. The About
  /// window's buttons open exactly these.
  @Test func licenceFilesResolveFromTheBundle() {
    let staged: (String) -> URL? = { name in URL(filePath: "/Applications/Oxbow.app/Contents/Resources/\(name)") }
    let about = AboutInfo(infoDictionary: info(), resource: staged)
    #expect(about.ffmpegLicense?.lastPathComponent == "COPYING.LGPLv2.1")
    #expect(about.ffmpegSourceRecord?.lastPathComponent == "FFMPEG-SOURCE.txt")
  }

  /// Disable license buttons when FFmpeg resources are absent.
  @Test func licenceFilesAreNilWhenAbsentFromTheBundle() {
    let about = AboutInfo(infoDictionary: info(), resource: noResources)
    #expect(about.ffmpegLicense == nil)
    #expect(about.ffmpegSourceRecord == nil)
  }

  // MARK: - Credits

  /// Check URL components: `URL(string:)` alone also accepts relative URLs.
  @Test func everyCreditLinksToAnAbsoluteHTTPSURL() {
    for credit in Credit.all {
      let url = URL(string: credit.urlString)
      #expect(url?.scheme == "https", "\(credit.name) has a non-HTTPS link: \(credit.urlString)")
      #expect(url?.host() != nil, "\(credit.name) has no host: \(credit.urlString)")
    }
  }

  /// The two the README calls out by licence, and which the About window is
  /// required to surface (docs/architecture.md §6, docs/ffmpeg.md §6).
  @Test func creditsIncludeTheTwoBundledExecutables() {
    let names = Credit.all.map(\.name)
    #expect(names.contains("TwitchDownloaderCLI"))
    #expect(names.contains("FFmpeg"))
  }
}

@Suite("Licence document")
struct LicenceDocumentTests {

  /// Both staged files are ASCII in practice, so this is the ordinary path.
  @Test func decodesUTF8Text() {
    let data = Data("GNU LESSER GENERAL PUBLIC LICENSE".utf8)
    let document = LicenceDocument(title: "FFmpeg License", data: data)
    #expect(document.text == "GNU LESSER GENERAL PUBLIC LICENSE")
  }

  /// Latin-1 fallback keeps non-UTF-8 license text readable.
  @Test func fallsBackToLatin1ForBytesThatAreNotUTF8() {
    let data = Data([0xA9, 0x20, 0x46, 0x46]) // © FF, in Latin-1
    let document = LicenceDocument(title: "FFmpeg License", data: data)
    #expect(document.text == "© FF")
  }

  @Test func keepsTheTitleItWasGiven() {
    let document = LicenceDocument(title: "FFmpeg Source", data: Data())
    #expect(document.title == "FFmpeg Source")
  }
}
