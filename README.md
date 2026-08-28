<p align="center">
  <img src="docs/icon-384.png" width="160" height="160" alt="Oxbow">
</p>

<h1 align="center">Oxbow</h1>

<p align="center"><strong>Twitch VODs, saved properly. For Mac.</strong></p>

<p align="center">
  <a href="https://github.com/barclay/oxbow/releases/latest"><strong>Download for macOS</strong></a>
  &nbsp;·&nbsp;
  <a href="https://getoxbow.app">getoxbow.app</a>
  &nbsp;·&nbsp;
  <a href="CHANGELOG.md">Changelog</a>
</p>

<p align="center"><sub>macOS 15+ · Apple Silicon · signed and notarized · MIT</sub></p>

---

*Paste a link, choose whether the chat comes along, and let it run. Your
favorite streams end up on your Mac, ready for the flight, the commute, or
anywhere the wifi gives up.*

<img src="docs/screenshot.jpg" alt="Oxbow downloading a VOD with its chat, showing the queue and a job's detail window" width="100%">

## What it does

**The video.** Best available quality by default, the whole VOD or a trimmed
range, written straight to a folder you choose. Clips too, from any of the
shapes a clip link comes in.

**The chat.** Half of what happened in a stream happened in the chat—the
bits, the spam, the one joke that ran into the ground. It comes along too,
rendered beside the video in a single file, BTTV, FFZ, and 7TV emotes and all.

**A queue you can walk away from.** Jobs run in order and expand to show every
step and its progress. The queue survives quitting, and an interrupted
composite continues from where it stopped rather than starting again—a
six-hour job killed at 90% recovers in about twenty minutes, not eighty-eight.

**Names you can read.** Files come out as `{streamer} - {date} - {title}`,
derived from the stream's own metadata and editable before the job starts.

**Nothing to install first.** The downloader, the renderer, and FFmpeg are all
inside the bundle. No Homebrew, no Python, no terminal.

Oxbow is young—0.2.x is its first release, and there are rough edges—but
every part of it runs end to end today.

## Getting started

1. **Download** the DMG from the
   [latest release](https://github.com/barclay/oxbow/releases/latest).
2. **Open it and drag Oxbow to Applications.** The app is signed with a
   Developer ID and notarized by Apple, so it opens on a double-click—no
   right-click-to-open, no Gatekeeper detour.
3. **Paste a Twitch link.** A VOD (`twitch.tv/videos/…`) or a clip
   (`twitch.tv/<channel>/clip/…`, `clips.twitch.tv/…`, or a bare slug). Oxbow
   fetches the stream's title, streamer, date, and thumbnail.
4. **Choose what you want.** Just the video, or the video with its chat
   rendered and composited beside it. Pick a quality, trim a range if you only
   want part of it, and choose where it lands.
5. **Add it to the queue and let it run.** Long jobs keep going in the
   background; the composite is readable while it's still being written.

## Requirements

- **macOS 15 or later.**
- **Apple Silicon.** Oxbow is arm64 only — Intel Macs are not supported. See
  "Scope trims for v1" in [`docs/architecture.md`](docs/architecture.md).

## Not affiliated with Twitch

Oxbow is an independent project with no affiliation with, endorsement by, or
sponsorship from Twitch Interactive, Inc. Twitch and the Twitch logo are
trademarks of Twitch Interactive, Inc., used here only to describe what the app
does. Downloaded video and chat remain the property of their respective rights
holders — please respect their copyright and Twitch's terms of service.

## Building

If you are only working on `OxbowKit` — the queue engine, argument builder,
output parser, and persistence layer — you need Xcode and nothing else:

```bash
git clone https://github.com/barclay/oxbow.git
cd oxbow
swift test
```

Building the **app bundle** needs more. Start with the submodule:

**Clone with submodules.** `vendor/TwitchDownloader` is a git submodule pinned
to an exact commit. A plain `git clone` leaves it empty and the build will fail
confusingly. It points at a mirror of upstream rather than at
`lay295/TwitchDownloader` directly — the mirror carries upstream's own history
unmodified plus tags that keep a pinned commit fetchable, and Oxbow adds no
code to it. See "submodule pin policy" in [`docs/development.md`](docs/development.md).

```bash
git clone --recurse-submodules https://github.com/barclay/oxbow.git
```

Already cloned without it:

```bash
git submodule update --init --recursive
```

Then you need the [.NET 10 SDK](https://dotnet.microsoft.com/download)
(`brew install --cask dotnet-sdk`) and Xcode. Build the bundled FFmpeg — an
LGPL, arm64, hardware-encoding build we compile ourselves because every
readily-available macOS binary is GPL:

```bash
./scripts/build-ffmpeg.sh
```

Full command reference is in [`docs/development.md`](docs/development.md); the contributor-facing
version is in [`CONTRIBUTING.md`](CONTRIBUTING.md).

Note that a local build is unsigned. Signing and notarization need a Developer
ID certificate tied to a specific Apple Developer account, so only the
maintainer can cut a distributable release.

## Contributing

Contributions are welcome — see [`CONTRIBUTING.md`](CONTRIBUTING.md). Most
changes only need `swift test` and no .NET or FFmpeg toolchain at all.

Architectural decisions and their rationale live in
[`docs/architecture.md`](docs/architecture.md), including a "Do not suggest" list of
things already considered and rejected.

Security issues should be reported privately — see [`SECURITY.md`](SECURITY.md).

## Licensing

Oxbow is [MIT](LICENSE). It bundles two other things:

- **TwitchDownloaderCLI** (MIT) — see `vendor/TwitchDownloader/LICENSE.txt`
- **FFmpeg** (LGPL 2.1+) — unmodified, built by `scripts/build-ffmpeg.sh`,
  which emits `COPYING.LGPLv2.1` and `FFMPEG-SOURCE.txt` recording the exact
  source and configure line so the binary can be reproduced.

See [`docs/ffmpeg.md`](docs/ffmpeg.md) for why we build FFmpeg ourselves.

## Third Party Credits

Downloads and chat rendering are performed by
[TwitchDownloaderCLI](https://github.com/lay295/TwitchDownloader) © lay295 and
contributors, bundled as a helper executable. Oxbow exists because upstream
ships a Windows WPF app and a cross-platform CLI, leaving Mac users with the
CLI only.

Video is encoded and finalized with [FFmpeg](https://ffmpeg.org/) © The FFmpeg
developers, built from unmodified source under LGPL 2.1+.

The bundled helper is a self-contained
[.NET](https://github.com/dotnet/runtime) application © Microsoft Corporation.

Chat renders are drawn with [SkiaSharp and HarfBuzzSharp](https://github.com/mono/SkiaSharp)
© Microsoft Corporation, and may use
[Noto Color Emoji](https://github.com/googlefonts/noto-emoji) © Google and
contributors or [Twemoji](https://github.com/jdecked/twemoji) © Twitter and
contributors, by way of TwitchDownloaderCLI.

For the full set of libraries reaching Oxbow through the bundled helper, see
upstream's
[THIRD-PARTY-LICENSES.txt](https://github.com/lay295/TwitchDownloader/blob/master/TwitchDownloaderCore/Resources/THIRD-PARTY-LICENSES.txt).
