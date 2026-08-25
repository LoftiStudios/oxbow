# Oxbow

Native macOS GUI for [TwitchDownloader](https://github.com/lay295/TwitchDownloader).
SwiftUI app that drives a bundled `TwitchDownloaderCLI` helper as a subprocess.

**Read `docs/architecture.md` first.** It holds the architecture decisions and their
rationale. This file holds the rules and commands.
`docs/ffmpeg.md` and `docs/signing.md` hold the two resolved spikes.

**Current state:** the app works end to end. It downloads a VOD or clip, its
chat, and a rendered chat video, into files named from the stream's own
metadata.

- **FFmpeg sourcing: resolved.** `./scripts/build-ffmpeg.sh` produces a verified
  LGPL 2.1+ arm64 binary. See `docs/ffmpeg.md`.
- **Signing + notarization: resolved and verified end to end**, including Xcode
  integration. The "Embed & Sign Helpers" Run Script phase
  (`scripts/embed-helpers.sh`) embeds the helper tree and FFmpeg into
  `Contents/MacOS` and signs them inside-out; there is deliberately no Copy
  Files phase, so the "Code Sign On Copy" trap cannot occur. Building without
  `build/helper` or `build/ffmpeg` succeeds with a warning, so UI work needs
  neither the .NET nor the FFmpeg toolchain. See `docs/signing.md`.
- **Deployment target: macOS 15.** `MIN_MACOS` in `scripts/build-ffmpeg.sh`
  must stay in lockstep with it.
- **OxbowKit: built and tested.** Job/step model, scheduler, queue engine,
  argument builder, status-line parser, atomic persistence with load-time
  reconciliation, per-step helper logs, and the async process wrapper.
- **The app: built and working.** Single window, queue list with expandable
  multi-step jobs, and an intake that takes a VOD or clip link, fetches the
  video's metadata, and derives filenames from it. Designs live in
  `docs/design/`.

Verified against the real bundled binaries, not only in tests: a chat + render
job run to completion, delivering a valid chat JSON and a playable h264 render
under metadata-derived names. Chat render matters most here — it is the reason
`docs/architecture.md` §3.5 keeps that part in C#, and our LGPL FFmpeg renders
it correctly with `h264_videotoolbox`.

**Not verified by anyone clicking it:** nothing in the SwiftUI layer has been
exercised by hand at the time of writing. `IntakeModel` carries the intake's
logic and is unit-tested; the views are not.

### Next

UI polish and native feel. The remaining functional gaps are release
infrastructure — `scripts/build.sh` and `scripts/notarize.sh` still do not
exist, there is no DMG, and no release workflow. The submodule also needs
re-pinning to a release tag before anything ships.

The About box is done (`Oxbow/About/`), and with it real versioning: the
marketing version is `MARKETING_VERSION` in `Config/Shared.xcconfig`, bumped
by hand as part of a release commit, and `CFBundleVersion` is the repository's
commit count, stamped into the built `Info.plist` by
`scripts/stamp-version.sh` on every build, local and CI alike. That script
also records the helper's `1.56.5+<sha>` string and the FFmpeg version as
`OXHelperVersion` and `OXFFmpegVersion`, which is where the About box reads
them from.

Local prerequisites, all now in place: .NET 10 SDK (`brew install --cask
dotnet-sdk`), a `Developer ID Application` certificate for team `M9WJGEJKBF`, and
notary credentials in the keychain as profile `oxbow-notary`.

**Workflow: changes land via PRs, not direct pushes to main.** CI (tests +
unsigned app build) must be green before merging. The repo is public; history
on main should be presentable.

---

## Layout

```
oxbow/
  Oxbow.xcodeproj            # the app; links OxbowKit as a local package
  Oxbow/                     # SwiftUI app source (+ OxbowTests/, OxbowUITests/)
  Package.swift              # SwiftPM package: the OxbowKit library
  Sources/OxbowKit/          # queue engine, CLI wrapper, parser, persistence
  Tests/OxbowKitTests/       # swift test; includes captured CLI-output fixtures
  Config/                    # Shared.xcconfig + gitignored Local.xcconfig (team)
  vendor/TwitchDownloader/   # git submodule, upstream C# — DO NOT EDIT
  scripts/                   # build-ffmpeg.sh, sign.sh, embed-helpers.sh, entitlements/
  docs/architecture.md       # decisions + rationale
  docs/design/               # per-subsystem design docs (task-queue.md)
  .github/workflows/
```

---

## Hard rules

Violating these produces builds that fail notarization or silently break on user
machines. They are not style preferences.

**Signing** — use `./scripts/sign.sh <bundle>`; it enforces all of this.
- Helper executables live in `Contents/MacOS/`. Never `Contents/Resources/` —
  executable code in a resource location fails notarization.
- **Every file under `Contents/MacOS` must be signed, whatever its type** — not
  just Mach-O binaries but managed `.dll` assemblies, `.json` runtime configs,
  even `.txt`. That directory is the bundle's code location, so codesign treats
  everything in it as a code object. For our bundle that's 205 files, not 19.
  Signing only the Mach-Os is the intuitive approach and it fails verification.
- Sign inside-out: every nested file first, app bundle last.
- Never use `codesign --deep` for signing — it applies one set of entitlements to
  every nested binary, which is backwards when the helper needs its own. Fine for
  verifying.
- The helper needs `com.apple.security.cs.allow-jit` and nothing more. This was
  tested, not assumed: without it CoreCLR fails with `HRESULT: 0x80070008`; with
  it alone, everything works. **Never add `disable-library-validation`** — needing
  it means something is signed wrong.
- The helper is embedded AND signed by one Run Script phase
  (`scripts/embed-helpers.sh`) — there is deliberately **no Copy Files phase**
  for it. Copy Files is where the "Code Sign On Copy" trap lives: Xcode's
  automatic signing re-signs embedded executables during the copy and clobbers
  their entitlements. Don't add one.
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
  `scripts/embed-helpers.sh` also stages both into `Contents/Resources`, and
  the About box reads them from there — the DMG copy is gone the moment the
  user drags the app out of it. The About box shows the text in place rather
  than handing the file to `NSWorkspace`: `COPYING.LGPLv2.1` has the extension
  `1`, which macOS cannot classify, so there is no application registered to
  open it.

**Upstream**
- `vendor/TwitchDownloader` is read-only. Changes go upstream as separate PRs, not
  as local edits. If something there needs to change, say so rather than patching.
- **The submodule pin is a deliberate choice, never an accident.** A gitlink is
  one exact SHA — there are no version ranges — so the only question is which
  commit and why.
  - **Release builds must pin to an upstream release tag.** A mid-stream commit
    is only reachable while it stays on a branch; if upstream rebases or
    force-pushes, an unreferenced SHA can be garbage collected and the submodule
    points at something nobody can fetch. Tags don't evaporate.
  - A non-tag pin is allowed during development **only with a recorded reason**
    (see below). Bumping the pin is its own commit whose message says what
    changed upstream and why we want it.
  - **Current pin: `d4122d8` (`1.56.5-12-g d4122d8`), deliberately ahead of the
    `1.56.5` tag** for "Migrate to 7TV emote-set API endpoint" (#1632) and
    "New m3u8 API + support vertical VODs" (#1631). Reverting to `1.56.5` would
    likely break 7TV emote resolution. Re-pin to the next release tag that
    contains both before shipping.
- The built helper self-identifies as `1.56.5+<full-sha>`, so a shipped DMG is
  traceable to an exact upstream commit. Surface that string in the About box.

**Secrets**
- Never commit `.p12`, `.p8`, or provisioning profiles. CI reads the signing
  certificate and the notary key from repository secrets; local builds read
  them from the keychain.
- **A Team ID is not a secret**, and this file states one. It is embedded in
  every binary we ship — `codesign -dv` on any distributed app prints it — so
  guarding it is theatre, and the rule that used to say otherwise was already
  contradicted by this file and by `docs/signing.md`. CI passes it as the
  repository *variable* `DEVELOPMENT_TEAM`; variables are the right primitive
  for config that is merely per-environment.
- `DEVELOPMENT_TEAM` still never goes in the pbxproj, for a different reason:
  it is per-developer, not per-project. It lives in the gitignored
  `Config/Local.xcconfig`, pulled in via an optional include from
  `Config/Shared.xcconfig`, so a fresh clone still builds (unsigned) and a
  contributor signing with their own team never edits a tracked file. Xcode's
  signing editor will happily write the team back into the project file —
  check the diff before committing pbxproj changes.

---

## Do not suggest

These were considered and rejected. Reasoning is in `docs/architecture.md`.

- **Avalonia** or any cross-platform UI framework.
- **UIKit / Mac Catalyst.** SwiftUI, dropping to AppKit where needed.
- **Mac App Store.** Distribution is Developer ID + notarized DMG, Homebrew cask
  on top.
- **Sparkle** for v1. Update check is a GitHub releases API call plus a banner.
- **Reimplementing chat render in Swift.** That's the one part genuinely worth
  keeping in C#.

---

## Commands

Run the OxbowKit test suite (needs only Xcode — no .NET or FFmpeg toolchain):

```bash
swift test
```

Build the bundled FFmpeg (LGPL, arm64, verified):

```bash
./scripts/build-ffmpeg.sh
```

Build the helper (upstream targets **.NET 10**). Never use
`-p:PublishProfile=MacOSArm64` — upstream's own profile sets `PublishSingleFile`
and `PublishTrimmed`, both of which we forbid. Override explicitly:

```bash
dotnet publish vendor/TwitchDownloader/TwitchDownloaderCLI -c Release -r osx-arm64 --self-contained true -p:PublishSingleFile=false -p:PublishTrimmed=false -p:PublishReadyToRun=false -p:DebugType=none -o build/helper
```

Sign a built bundle (inside-out; helper first, bundle last):

```bash
./scripts/sign.sh build/Oxbow.app
```

`scripts/build.sh` (assemble the bundle) and `scripts/notarize.sh`
(`notarytool submit --wait`, then `stapler staple`) do not exist yet — the
verified pipeline in `docs/signing.md` was driven manually. They land with the
app target, which is what defines the bundle they operate on.

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
- Always invoke the CLI with `--banner=false`. It is a **per-verb** option, not a
  global one, so it goes after the verb: `TwitchDownloaderCLI videodownload
  --banner=false ...`. Passing it before the verb is a parse error.
- **Always pass `--collision Overwrite`.** The default is `Prompt`, which on an
  output name collision blocks reading a stdin that never arrives — as a
  subprocess that means hanging forever with no output and no error. We always
  write into our own workspace first, so overwriting there is safe.
- **Any option whose value starts with `-` must use `--opt=value`.** The
  space-separated form makes CommandLineParser read the value as more options:
  `--output-args '-c:v …'` fails with `Option 'c' is unknown`.

---

## Open questions

Flag these rather than deciding unilaterally:

- **Process wrapper vs. NativeAOT dylib.** Currently (A), the process wrapper.
  (B) is better long-term but is a separate project with its own C ABI design.
- Minimum supported macOS version — not yet set.
- Final app name. "Oxbow" is a working name; see `docs/architecture.md` §6.
