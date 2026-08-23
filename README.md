# Oxbow

VOD downloader and chat renderer for macOS.

A native SwiftUI front end for [TwitchDownloader](https://github.com/lay295/TwitchDownloader),
which ships a Windows WPF app and a cross-platform CLI — leaving Mac users with
the CLI only.

Not affiliated with Twitch Interactive, Inc.

> **Status: pre-alpha.** No application code yet. The build and signing
> pipeline works end to end; the task queue is designed and not yet built.
> See [`docs/handoff.md`](docs/handoff.md).

## Building

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

Full command reference is in [`CLAUDE.md`](CLAUDE.md).

## Licensing

Oxbow is MIT. It bundles two other things:

- **TwitchDownloaderCLI** (MIT) — see `vendor/TwitchDownloader/LICENSE.txt`
- **FFmpeg** (LGPL 2.1+) — unmodified, built by `scripts/build-ffmpeg.sh`,
  which emits `COPYING.LGPLv2.1` and `FFMPEG-SOURCE.txt` recording the exact
  source and configure line so the binary can be reproduced.

See [`docs/ffmpeg.md`](docs/ffmpeg.md) for why we build FFmpeg ourselves.
