import Foundation
import Testing
@testable import Oxbow

@Suite("About info")
struct AboutInfoTests {

  /// The keys `scripts/stamp-version.sh` writes, plus the ones
  /// `GENERATE_INFOPLIST_FILE` writes from `Config/Shared.xcconfig`. A fully
  /// populated bundle; individual tests remove one key to describe what a
  /// build missing that piece should say.
  private func info(
    name: String? = "Oxbow",
    shortVersion: String? = "0.1.0",
    build: String? = "73",
    copyright: String? = "© 2026 barclay loftus. MIT licensed.",
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

  /// The form the standard macOS About panel uses, and the one a bug report
  /// needs: the semver users talk about plus the build number that pins it to
  /// an exact commit.
  @Test func versionLineCombinesSemverAndBuildNumber() {
    let about = AboutInfo(infoDictionary: info(), resource: noResources)
    #expect(about.versionLine == "Version 0.1.0 (73)")
  }

  /// A tree with no git history keeps the `CURRENT_PROJECT_VERSION` fallback
  /// rather than gaining a fake build number, so the parenthesised half has
  /// to be droppable without leaving stray punctuation behind.
  @Test func versionLineOmitsAnAbsentBuildNumber() {
    let about = AboutInfo(infoDictionary: info(build: nil), resource: noResources)
    #expect(about.versionLine == "Version 0.1.0")
  }

  /// Never render "Version  (73)". If the marketing version is gone the
  /// bundle is malformed, and saying so is more useful than a blank.
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
    #expect(about.copyright == "© 2026 barclay loftus. MIT licensed.")
  }

  // MARK: - Bundled components

  /// The string that makes a shipped build traceable to an exact upstream
  /// commit (docs/development.md, "Upstream").
  @Test func helperVersionReadsTheStampedKey() {
    let about = AboutInfo(infoDictionary: info(), resource: noResources)
    #expect(about.helperVersion == "1.56.5+d4122d80214b08b3c7078003aae43088e601a435")
  }

  /// The UI-only build CONTRIBUTING.md promises — no .NET toolchain, so
  /// `stamp-version.sh` omits the key. The About window must say the helper
  /// is absent rather than imply a version it does not have.
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

  /// A build with no FFmpeg has no licence text either. The buttons disable
  /// rather than opening nothing.
  @Test func licenceFilesAreNilWhenAbsentFromTheBundle() {
    let about = AboutInfo(infoDictionary: info(), resource: noResources)
    #expect(about.ffmpegLicense == nil)
    #expect(about.ffmpegSourceRecord == nil)
  }

  // MARK: - Credits

  /// These links are the attribution half of an MIT and an LGPL obligation,
  /// so a typo in one is a compliance problem rather than a cosmetic one.
  /// `URL(string:)` accepts almost anything as a relative URL, so assert the
  /// parts a missing scheme or a fat-fingered host would actually break.
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

  /// The licence text is a distribution obligation, so a stray high byte —
  /// a © in some other encoding, say — must not blank the whole document.
  /// Latin-1 maps every possible byte, so this fallback cannot itself fail.
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
