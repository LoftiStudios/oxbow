# Oxbow

Native macOS GUI for [TwitchDownloader](https://github.com/lay295/TwitchDownloader).
SwiftUI app that drives a bundled `TwitchDownloaderCLI` helper as a subprocess.

**Read `docs/handoff.md` first.** It holds the architecture decisions and their
rationale. This file holds the rules and commands.
`docs/ffmpeg.md` holds the resolved FFmpeg sourcing/licensing plan.

**Current state:** no application code yet.

- FFmpeg sourcing is **resolved** — `./scripts/build-ffmpeg.sh` produces a verified
  LGPL 2.1+ arm64 binary. See `docs/ffmpeg.md`.
- Next task is the **signing spike** (`docs/handoff.md` §9), widened to cover the
  real bundle: `TwitchDownloaderCLI` (which drags in SkiaSharp) plus our FFmpeg.
  Do not start building UI before that loop goes green.
- Two prerequisites are **not yet met** on this machine: the .NET SDK is not
  installed, and there is no **Developer ID Application** certificate in the
  keychain (only Apple Development, plus an Apple Distribution cert belonging to a
  different organisation). Both block the signing spike.

---

## Layout

```
oxbow/
  Oxbow.xcodeproj
  Oxbow/                     # SwiftUI app source
  vendor/TwitchDownloader/   # git submodule, upstream C# — DO NOT EDIT
  scripts/                   # build, sign, notarize
  docs/handoff.md            # decisions + rationale
  .github/workflows/
```

---

## Hard rules

Violating these produces builds that fail notarization or silently break on user
machines. They are not style preferences.

**Signing**
- Helper executables live in `Contents/MacOS/`. Never `Contents/Resources/` —
  executable code in a resource location fails notarization.
- Sign inside-out: every nested Mach-O first, app bundle last.
- Never use `codesign --deep`. Sign each file explicitly.
- "Code Sign On Copy" must stay OFF for the embedded helper. Xcode's automatic
  signing will otherwise re-sign it during Copy Files and clobber its entitlements.
  The helper is signed in a Run Script phase that runs *after* embedding.
- Entitlements are per-process. The helper needs its own; the app's do not
  propagate to child processes.

**Building the helper**
- Never `-p:PublishSingleFile=true`. It extracts unsigned native libs at runtime
  and forces `disable-library-validation`. Publish a directory and sign each file.
- arm64 only for v1. Do not add x64 or lipo a universal binary without discussion.

**FFmpeg**
- Build it with `./scripts/build-ffmpeg.sh`. Never vendor a prebuilt — every
  readily-available macOS FFmpeg is GPL (they all enable libx264). Never add
  `--enable-gpl`, `--enable-nonfree`, or `--enable-version3` to that script.
- **Always pass `--output-args` on chat render.** The CLI's default is
  `-c:v libx264 …`, which is a GPL encoder and is simply absent from our binary —
  the render fails outright. Use `-c:v h264_videotoolbox -b:v {bitrate}`.
  VideoToolbox is bitrate-targeted; there is no `-crf` equivalent.
- **Never forward `--sharpening`.** It appends the `smartblur` filter, which is
  GPL-only. Build an `unsharp` filter string instead (LGPL, present in our build).
- Always pass `--ffmpeg-path` explicitly, and never expose the CLI's `ffmpeg` verb
  in the GUI. That verb is the only path that triggers the runtime downloader; a
  downloaded binary isn't signed and won't execute on Apple Silicon.
- Ship `COPYING.LGPLv2.1` and `FFMPEG-SOURCE.txt` (both emitted into
  `build/ffmpeg/`) in the DMG, and reference them from the About box.

**Upstream**
- `vendor/TwitchDownloader` is read-only. Changes go upstream as separate PRs, not
  as local edits. If something there needs to change, say so rather than patching.

**Secrets**
- Never commit `.p12`, `.p8`, provisioning profiles, or Team IDs. CI reads them
  from repository secrets; local builds read them from the keychain.

---

## Do not suggest

These were considered and rejected. Reasoning is in `docs/handoff.md`.

- **Avalonia** or any cross-platform UI framework.
- **UIKit / Mac Catalyst.** SwiftUI, dropping to AppKit where needed.
- **Mac App Store.** Distribution is Developer ID + notarized DMG, Homebrew cask
  on top.
- **Sparkle** for v1. Update check is a GitHub releases API call plus a banner.
- **Reimplementing chat render in Swift.** That's the one part genuinely worth
  keeping in C#.

---

## Commands

Build the bundled FFmpeg (LGPL, arm64, verified):

```bash
./scripts/build-ffmpeg.sh
```

Build the helper (upstream targets **.NET 10**; the SDK is not yet installed here):

```bash
dotnet publish vendor/TwitchDownloader/TwitchDownloaderCLI \
  -c Release -r osx-arm64 --self-contained true
```

Build, sign, notarize:

```bash
./scripts/build.sh
./scripts/sign.sh        # inside-out; helper first, bundle last
./scripts/notarize.sh    # notarytool submit --wait, then stapler staple
```

Verify a signed bundle before shipping:

```bash
codesign --verify --deep --strict --verbose=2 build/Oxbow.app
spctl -a -vvv -t install build/Oxbow.app
xcrun stapler validate build/Oxbow.dmg
```

(`--deep` is fine for *verification*. It is not fine for signing.)

---

## Conventions

- SwiftUI first; AppKit only where SwiftUI can't express something.
- Async/await for the process wrapper. No completion-handler APIs in new code.
- The task queue is the core abstraction, not the forms. Model it properly:
  queued / running / cancelled / failed / done, with per-task progress.
- Helper output goes to a temp dir or the app container; the **Swift parent** moves
  finished files to the user's chosen location. Keeps the helper sandbox-agnostic.
- CLI progress currently arrives as text on stdout:
  `[STATUS] - Downloading 100% [2/5]`. Parsing is deliberately isolated in one
  file so it can be swapped for structured output later.
- Always invoke the CLI with `--banner=false`.

---

## Open questions

Flag these rather than deciding unilaterally:

- **Process wrapper vs. NativeAOT dylib.** Currently (A), the process wrapper.
  (B) is better long-term but is a separate project with its own C ABI design.
- Minimum supported macOS version — not yet set.
- Final app name. "Oxbow" is a working name; see `docs/handoff.md` §6.
