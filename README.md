# Oxbow

VOD downloader and chat renderer for macOS.

A native SwiftUI front end for [TwitchDownloader](https://github.com/lay295/TwitchDownloader),
which ships a Windows WPF app and a cross-platform CLI — leaving Mac users with
the CLI only.

Not affiliated with Twitch Interactive, Inc.

> **Status: pre-alpha.** The build and signing pipeline works end to end, and
> the core library (`OxbowKit` — task queue, CLI wrapper, output parser,
> persistence) is built and tested. There is no app UI yet.
> See [`docs/architecture.md`](docs/architecture.md).

## Requirements

- **macOS 15 or later.**
- **Apple Silicon.** v1 is arm64 only — Intel Macs are not supported. See
  "Scope trims for v1" in [`docs/architecture.md`](docs/architecture.md).

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
to an exact upstream commit. A plain `git clone` leaves it empty and the build
will fail confusingly.

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
contributors, bundled as a helper executable.

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
