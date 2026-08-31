import AppKit
import SwiftUI

/// The About window.
///
/// This is where three separate obligations land, which is why it exists as a
/// window of our own rather than as the stock `orderFrontStandardAboutPanel`:
///
///   - the trademark disclaimer (`docs/architecture.md` §6),
///   - attribution for TwitchDownloaderCLI (MIT) and FFmpeg (LGPL 2.1+),
///     together with the LGPL's licence text and source record
///     (`docs/ffmpeg.md` §6),
///   - the helper's `1.56.5+<sha>` build string, which is what makes a
///     shipped DMG traceable to an exact upstream commit
///     (`docs/development.md`, "Upstream").
///
/// The standard panel offers one small credits scroller and nowhere to put a
/// control, which is not enough room for the licence text to be genuinely
/// reachable.
struct AboutView: View {
  let info: AboutInfo

  /// Non-nil while a licence file is on screen. `LicenceDocument` is
  /// `Identifiable`, so `sheet(item:)` both presents and carries the content.
  @State private var licence: LicenceDocument?

  var body: some View {
    VStack(spacing: 0) {
      identity
      Divider()
      details
      Divider()
      footer
    }
    .frame(width: 460)
    .sheet(item: $licence) { LicenceSheet(document: $0) }
  }

  private var identity: some View {
    VStack(spacing: 6) {
      if let icon = NSImage(named: NSImage.applicationIconName) {
        Image(nsImage: icon)
          .resizable()
          .frame(width: 96, height: 96)
          .accessibilityHidden(true)
      }
      Text(info.applicationName)
        .font(.title2.weight(.semibold))
      // Selectable because this is the line a bug report has to quote.
      Text(info.versionLine)
        .font(.callout)
        .foregroundStyle(.secondary)
        .textSelection(.enabled)
      if let copyright = info.copyright {
        Text(copyright)
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
    .frame(maxWidth: .infinity)
    .padding(.vertical, 20)
  }

  private var details: some View {
    VStack(alignment: .leading, spacing: 16) {
      // Nominative use: naming Twitch to say what the app works with is
      // fine, implying a relationship is not. Kept as running text at the
      // top rather than buried in the credits, because being seen is the
      // entire point of it.
      Text(
        """
        Oxbow is not affiliated with, endorsed by, or sponsored by Twitch \
        Interactive, Inc. Twitch is a trademark of Twitch Interactive, Inc.
        """
      )
      .font(.callout)
      .foregroundStyle(.secondary)
      .fixedSize(horizontal: false, vertical: true)

      VStack(alignment: .leading, spacing: 4) {
        component("Helper", value: info.helperVersion)
        component("FFmpeg", value: info.ffmpegVersion.map { "\($0) · LGPL 2.1+" })
      }

      VStack(alignment: .leading, spacing: 6) {
        Text("Acknowledgements")
          .font(.headline)
        ScrollView {
          VStack(alignment: .leading, spacing: 10) {
            ForEach(Credit.all) { credit in
              CreditRow(credit: credit)
            }
          }
          .padding(10)
          .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(height: 170)
        .background(.quaternary, in: .rect(cornerRadius: 6))
      }
    }
    .padding(20)
  }

  private var footer: some View {
    HStack(spacing: 10) {
      Spacer(minLength: 0)
      // Disabled rather than hidden: a build with no FFmpeg in it should say
      // so by showing an unavailable control, not by quietly having fewer.
      Button("FFmpeg License") {
        licence = LicenceDocument(title: "FFmpeg License", url: info.ffmpegLicense)
      }
      .disabled(info.ffmpegLicense == nil)

      Button("FFmpeg Source") {
        licence = LicenceDocument(title: "FFmpeg Source", url: info.ffmpegSourceRecord)
      }
      .disabled(info.ffmpegSourceRecord == nil)
    }
    .padding(.horizontal, 20)
    .padding(.vertical, 14)
  }

  private func component(_ label: String, value: String?) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 8) {
      Text(label)
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
        .frame(width: 56, alignment: .leading)
      // The helper string is a 40-character sha and the whole reason it is
      // here is that someone can copy it into an issue.
      Text(value ?? "Not embedded")
        .font(.system(.caption, design: .monospaced))
        .foregroundStyle(value == nil ? .secondary : .primary)
        .textSelection(.enabled)
        .fixedSize(horizontal: false, vertical: true)
    }
    .accessibilityElement(children: .combine)
  }
}

/// One attribution line. A `Link` when the URL parses, plain text when it does
/// not — a malformed link is caught by `AboutInfoTests`, so this fallback is
/// about never dropping the notice itself, which is the part MIT and the LGPL
/// actually require.
private struct CreditRow: View {
  let credit: Credit

  var body: some View {
    VStack(alignment: .leading, spacing: 1) {
      if let url = credit.url {
        Link(credit.name, destination: url)
          .font(.callout.weight(.medium))
      } else {
        Text(credit.name)
          .font(.callout.weight(.medium))
      }
      Text(credit.detail)
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

/// A bundled licence file, shown in place because macOS has no application
/// registered for `COPYING.LGPLv2.1` — see `LicenceDocument`.
private struct LicenceSheet: View {
  let document: LicenceDocument
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    VStack(spacing: 0) {
      // A sheet has no title bar and `navigationTitle` does nothing to one on
      // macOS, so without this header the two footer buttons both open an
      // unlabelled panel of text.
      HStack {
        Text(document.title)
          .font(.headline)
        Spacer(minLength: 0)
      }
      .padding(12)
      Divider()
      ScrollView {
        Text(document.text)
          .font(.system(.caption, design: .monospaced))
          .textSelection(.enabled)
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(16)
      }
      Divider()
      HStack {
        Spacer(minLength: 0)
        Button("Done") { dismiss() }
          .keyboardShortcut(.defaultAction)
      }
      .padding(12)
    }
    .frame(width: 640, height: 520)
  }
}

#Preview("Fully embedded") {
  AboutView(
    info: AboutInfo(
      infoDictionary: [
        "CFBundleName": "Oxbow",
        "CFBundleShortVersionString": "0.1.0",
        "CFBundleVersion": "73",
        "NSHumanReadableCopyright": "© 2026 Lofti Studios LLC. MIT licensed.",
        "OXHelperVersion": "1.56.5+d4122d80214b08b3c7078003aae43088e601a435",
        "OXFFmpegVersion": "8.1.2",
      ],
      resource: { URL(filePath: "/tmp/\($0)") }))
}

/// The UI-only build CONTRIBUTING.md promises: no .NET, no FFmpeg, so no
/// component versions and nothing for the buttons to open.
#Preview("No helpers embedded") {
  AboutView(
    info: AboutInfo(
      infoDictionary: [
        "CFBundleName": "Oxbow",
        "CFBundleShortVersionString": "0.1.0",
        "CFBundleVersion": "73",
        "NSHumanReadableCopyright": "© 2026 Lofti Studios LLC. MIT licensed.",
      ],
      resource: { _ in nil }))
}
