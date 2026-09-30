# Developing Oxbow

Native macOS GUI for [TwitchDownloader](https://github.com/lay295/TwitchDownloader).
SwiftUI app that drives a bundled `TwitchDownloaderCLI` helper as a subprocess.

**Read `docs/architecture.md` first.** It holds the architecture decisions and their
rationale. This file holds the rules and commands for building and changing it.
`docs/ffmpeg.md`, `docs/signing.md`, and `docs/composite-performance.md` hold the
resolved spikes. Read the last one before proposing anything that claims to make
compositing faster — the step is bound by the hardware H.264 encoder, and six
plausible optimisations have already been measured at zero.
`docs/twitch-metadata.md` records which of Twitch's metadata fields can be
trusted and which are measurably wrong — read it before writing anything that
reasons about a video before downloading it.
`docs/design/composite-quality.md` is the same kind of document for how the
composited chat *looks*. Read it before proposing anything about the chat
renderer, its arguments, the intermediate encode, or the composite's bitrate:
the renderer is not the problem, four plausible fixes are measured at
approximately zero, and the bitrate a composite needs spans 7.5x across real
content with nothing in the metadata predicting it.
`docs/design/settings.md` records why a default quality is stored as a *cap*
rather than a rendition name — renditions are named per video and some carry
no resolution, so no name is stable across two videos — and why saving
defaults is an explicit opt-in rather than last-used-wins.

## Things worth knowing first

- **Deployment target: macOS 26, Apple Silicon only.** `MIN_MACOS` in
  `scripts/build-ffmpeg.sh` must stay in lockstep with it.
- **UI work needs neither the .NET nor the FFmpeg toolchain.** Building without
  `build/helper` or `build/ffmpeg` succeeds with a warning; the "Embed & Sign
  Helpers" Run Script phase (`scripts/embed-helpers.sh`) skips what is absent.
  See `docs/signing.md` for what it does when both are present.
- **Chat is drawn by Oxbow's own renderer by default.** The CLI downloads the
  chat JSON with images embedded; `Sources/OxbowKit/ChatRender` draws it, and
  for a composite draws straight into the composite's FFmpeg with no
  intermediate file. The CLI's `chatrender` remains as a fallback behind the
  Settings switch "Draw chat with Oxbow's renderer", for one release.
  `docs/design/native-chat-render.md` has the design and the measurements.

**The SwiftUI layer is verified by hand, not by tests.** `IntakeModel` carries
the intake's logic and is unit-tested; the views are not, and the coverage gate
deliberately scopes to `Sources/OxbowKit` for that reason. A change to a view is
a change nothing will catch for you — click it.

Local prerequisites for a signed release build: .NET 10 SDK (`brew install --cask
dotnet-sdk`), a `Developer ID Application` certificate for the Lofti Studios, LLC
team `Z4PBYBS53X` (the personal team `M9WJGEJKBF` before the move in
`docs/signing.md` §9), and
notary credentials in the keychain as profile `oxbow-notary`. The marketing
version is `MARKETING_VERSION` in `Config/Shared.xcconfig`, bumped by hand as
part of a release commit; `CFBundleVersion` is the repository's commit count,
stamped into the built `Info.plist` by `scripts/stamp-version.sh` on every
build, local and CI alike. That script also records the helper's `1.56.5+<sha>`
string and the FFmpeg version as `OXHelperVersion` and `OXFFmpegVersion`, which
is where the About box reads them from.

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
  docs/twitch-metadata.md    # which Twitch metadata to trust, and why
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
- **Always pass `--output-args` on the CLI's chat render**, for as long as that
  path exists. The CLI's default is
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
  - **Release builds must pin to a tag — but not necessarily upstream's.** The
    property that matters is *durable reachability*: a mid-stream commit is only
    reachable while it stays on a branch, so if upstream rebases or force-pushes,
    an unreferenced SHA can be garbage collected and the submodule points at
    something nobody can fetch. Tags don't evaporate. Two kinds qualify:
    - **An upstream release tag** (`1.56.5`). Preferred, because it is code
      upstream has release-tested.
    - **An `oxbow-pin-*` anchor tag** in our mirror, `barclay/TwitchDownloader`.
      For commits upstream has not tagged yet. Upstream releases every 3-5
      months, so a policy of upstream-tags-only means waiting a quarter for
      fixes that are already on master and already verified here.
  - **The submodule URL points at the mirror**, not at `lay295/TwitchDownloader`.
    That is what makes an anchor tag mean anything at fetch time — a tag in a
    repo we do not control is not a guarantee. The mirror carries all 112 of
    upstream's tags plus our anchors, and **diverges from upstream by nothing**:
    we never commit to it, never carry patches, and fast-forward it from
    upstream. Track upstream directly from inside the submodule:

    ```bash
    git -C vendor/TwitchDownloader remote add upstream https://github.com/lay295/TwitchDownloader.git
    git -C vendor/TwitchDownloader fetch --tags upstream
    ```

  - **Cutting an anchor tag.** Name it `oxbow-pin-<git describe output>`, make it
    annotated, and say in the message why the pin is ahead of the last release:

    ```bash
    git -C vendor/TwitchDownloader tag -a "oxbow-pin-$(git -C vendor/TwitchDownloader describe --tags)" -m "why this pin is ahead of the last release"
    git -C vendor/TwitchDownloader push git@github.com:barclay/TwitchDownloader.git --tags
    ```

  - **An anchor tag makes a commit durable. It says nothing about whether it
    works.** Upstream's release testing is exactly what you give up by pinning
    past a tag, and nothing replaces it automatically. A pin-bump onto an anchor
    has to carry its own verification against the real binary and decoded output,
    the way `docs/design/chat-and-render.md` §1 does — see `docs/twitch-metadata.md`
    §7 for why an exit code is not enough.
  - A pin that no tag points at is allowed during development **only with a
    recorded reason** (see below). Bumping the pin is its own commit whose
    message says what changed upstream and why we want it.
  - **Current pin: `d4122d8`, tagged `oxbow-pin-1.56.5-12-gd4122d8`** in the
    mirror — twelve commits ahead of `1.56.5` for "Migrate to 7TV emote-set API
    endpoint" (#1632) and "New m3u8 API + support vertical VODs" (#1631).
    Reverting to `1.56.5` breaks 7TV emote resolution, so the anchor is what
    lets 0.2.0 ship without regressing emotes. BTTV, FFZ and 7TV emote
    resolution were verified by hand on this pin before release. Re-pin to the
    next upstream release tag containing both once one exists.
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
- **Rendering chat on the GPU, or with Skia, to make it faster.** Neither is
  the limit. The native renderer draws 5,700–12,000 frames/s on the CPU
  against the ~170 the encoder takes at 1080p60. Chat render sat on this list
  as "keep it in C#" until September 2026; measurement overturned that, and
  `docs/design/native-chat-render.md` has the numbers.


---

## Commands

Run the OxbowKit test suite (needs only Xcode — no .NET or FFmpeg toolchain):

```bash
swift test
```

**`swift test` is not enough on its own if you touched anything public in
`Sources/OxbowKit`.** It builds only the SwiftPM package — `Sources/OxbowKit`
plus `Tests/OxbowKitTests` — and never the Xcode app target. So a change to a
public type can leave `Oxbow/` and `OxbowTests/` failing to compile while
`swift test` stays green. That is not hypothetical: adding one `StepKind` case
left the app un-buildable across four consecutive changes, through two
non-exhaustive switches and eleven type errors, with every package run passing.
Run both:

```bash
xcodebuild test -project Oxbow.xcodeproj -scheme Oxbow -only-testing:OxbowTests CODE_SIGNING_ALLOWED=NO
```

Run the suite with a coverage report over `Sources/OxbowKit`. This is what CI
runs in place of a bare `swift test`, so a green run here is a green run there:

```bash
./scripts/coverage.sh
```

It fails below a floor of **90% line coverage**, set in the script. The floor
sits a few points under the real number (94.55% at 0.2.0) on purpose: a gate
pinned to today's exact figure turns every honest refactor red and trains
people to bump the floor without reading why it moved. It is a regression
alarm for a file landing untested, not a ratchet. Raise it in its own commit,
when the real number has held higher for a while.

**Scope is `Sources/OxbowKit` and nothing else.** The SwiftUI layer is verified
by hand and has close to no automated coverage, so a repository-wide number
would average a well-tested engine against untested views and move for reasons
nobody could act on. Measuring the wrong thing precisely is worse than not
measuring, because the result looks like a fact.

`--no-test` reuses the profdata already on disk, `--floor N` overrides the
floor for one run, and `--lcov <path>` writes an lcov file if you want to feed
an editor's coverage gutter. Under Actions the per-file table is written to the
job summary.

### The FFmpeg-gated tests, and why a green run does not cover them

Two suites run against the real `build/ffmpeg/ffmpeg` instead of a fixture, and
both are gated so a checkout without that binary still goes green:

| Suite | Gate | Cost when it runs |
|---|---|---|
| `SidecarRewriteFFmpegTests` | `build/ffmpeg/ffmpeg` exists | well under a second |
| `ResumeEndToEndTests` | `OXBOW_RESUME_E2E=1` *and* the binary | network, real encodes, minutes |

**Neither runs on a pull request.** `ci.yml` runs `scripts/coverage.sh` and
deliberately builds no FFmpeg, so `SidecarRewriteFFmpegTests` skips there — and
a skip nobody looks at is indistinguishable from a pass. Treat a green
`swift test` on a checkout with no FFmpeg as saying nothing at all about resume
or the sidecar.

`full-build.yml` now runs `SidecarRewriteFFmpegTests` against the binary it has
already built, on pushes to main and nightly, and fails the job outright if
that binary is missing rather than letting the suite skip. That is the backstop,
not the loop you should be working in: it is not a PR gate and a cold run is
tens of minutes, so on anything touching FFmpeg arguments, run it locally.

Run it deliberately after touching resume, the sidecar, or `ArgumentBuilder`'s
`.composite` case, and read the result rather than the exit code:

```bash
./scripts/build-ffmpeg.sh && swift test --filter SidecarRewriteFFmpegTests
```

It must say `Suite "Sidecar rewrite spans the whole source" passed`. With no
binary it says `skipped` instead and the run is still green — so read that
line, not the exit code.

**Run it against `MINIMAL=1` too when you change what FFmpeg is asked to do.**
The minimal component set is the variant that breaks first, and it is the only
cheap check that a new argument has not reached for a component we do not
build. Both of the gaps this suite has found so far were minimal-only: the
`ipod` muxer that `audio.m4a` resolves to, missing outright, and — in the test
itself — an `s16le` input and a `pcm_s16le` encoder it had no reason to need.
`docs/ffmpeg.md` §4 records the component surface each invocation implies.

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

Package a signed, stapled bundle into the release DMG. `mise run setup` first;
this needs dmgbuild, which lives in the mise-managed `.venv`:

```bash
mise exec -- ./scripts/package-dmg.sh --notarize
```

Locally that reads notary credentials from the keychain profile `oxbow-notary`.
CI has no keychain profile, so setting `NOTARY_KEY`, `NOTARY_KEY_ID` and
`NOTARY_ISSUER` switches it to an App Store Connect API key.

Regenerate the README screenshot. Launches the real app against a checked-in
queue fixture and captures its window:

```bash
mise run screenshots
```

**The fixture exists so the published screenshot contains no real person.**
`docs/screenshot.png` goes stale every time the interface moves, and producing
it used to mean pointing Oxbow at real VODs and photographing the result — which
put real streamers' names, titles and thumbnails into an image on a public
README. That is a permission question, and it should not have to be answered
again at every release.

Nothing in the harness knows about layout: it knows a window title and a JSON
file, which is what lets it survive the interface changes it exists to keep up
with. The pieces:

- `Oxbow/ScreenshotFixture.swift` reads `OXBOW_FIXTURE_DIR`, and
  `AppComposition.defaultSupportDirectory()` returns it when set — the one place
  the app decides where its state lives, so no view is involved. **`#if DEBUG`**,
  so the hook is not compiled into a release build at all.
- `QueueController` passes `runsWork: false` to `QueueEngine.start` for a
  fixture run. Without it the queue is live: `tick()` would try to download the
  invented video ids and settle every step as failed, and `Reconciler` would
  demote the `running` step first, so a fixture could only ever show a finished
  queue — the one state that displays none of the per-step progress.
- `scripts/screenshots/fixture/queue.json` is the app's own persisted format,
  not a bespoke one. Regenerate it from a real queue with
  `scripts/screenshots/make-fixture.py`, which replaces every identifying field
  and marks one job mid-flight. Starting from a file the app wrote is what keeps
  it decodable: `Step.progress` is non-optional, and a queue.json the store
  cannot decode is silently moved to `queue.json.bak`, leaving a blank window
  rather than an error.
- Windows are matched **by PID**, never by application name. The run launches a
  second Oxbow beside whatever you already have open, and matching on the name
  captured the developer's real queue — silently, since the image looked
  perfectly correct.
- `scripts/screenshots/fixture/watches.json` is the watch list, written whole
  by `make-fixture.py` rather than transformed from a real one: a `Watch` has no
  Swift-Codable exotica to get wrong by hand. Two of its three channels are the
  streamers the queue is full of, because a sidebar naming channels nobody in
  the queue is watching reads as two screenshots stitched together. The poller
  does **not** run on a fixture launch — same reasoning as `runsWork: false`
  above, since a sweep would spend the capture failing to reach Twitch for three
  logins that do not exist.
- `ScreenshotFixture.videoInfo(for:)` answers per video id —
  `videoinfo-<id>.json` first, `videoinfo.json` otherwise. One canned answer for
  every id was enough while the intake was the only surface asking; the
  inspector asks about the *selected job*, so a single answer put one video's
  title on a card beside a row naming another.

It needs Screen Recording permission for your terminal; without it
`screencapture` writes a blank file rather than failing, so the script checks
the output size and says so.

The window layout is a background image plus a `.DS_Store`, and the two must
agree: the artwork paints an arrow between two points and Finder draws the real
icons on top of it. The coordinates live in `scripts/dmg/settings.py` and in
`scripts/dmg/make-background.swift`, which prints them on every run. Regenerate
the artwork with:

```bash
mise run background
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

Undecided. Raise either in an issue before building on it:

- **Process wrapper vs. NativeAOT dylib.** Currently (A), the process wrapper.
  (B) is better long-term but is a separate project with its own C ABI design.
- Final app name. "Oxbow" is a working name; see `docs/architecture.md` §6.
