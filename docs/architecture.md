# Architecture: macOS GUI for TwitchDownloader

**Status:** planning complete, no code written yet
**Written:** 2026-08-23

This document exists so a future maintainer (most likely me, months from now)
can pick up without re-deriving the decisions below. Read it before touching any files.
Everything here was decided deliberately — if you want to change something,
change it on purpose, not by accident.

---

## 1. Goal

Build a native macOS GUI for [lay295/TwitchDownloader](https://github.com/lay295/TwitchDownloader),
which currently ships a WPF UI for Windows and a cross-platform CLI. Mac users get
the CLI only.

**Scope for v1:** download a VOD or clip at a chosen quality, download chat, render
chat to video. Roughly parity with the CLI's main verbs. Mass downloader and the
more exotic WPF features are explicitly out of scope for v1.

**Non-goals:** Windows, Linux, iOS. Cross-platform UI frameworks. App Store.

---

## 2. The two-repo split (important)

There are two artifacts with two different homes. Conflating them is the main way
this project goes wrong.

**This repo** — the Swift/SwiftUI app. Ours. Own repo, own name, own release
cadence, own directional decisions about UI. Upstream does not own it and should
never be asked to maintain an Xcode project, a code-signing pipeline, or an Apple
Developer account.

**Upstream** — the C# project. Anything we need from it goes back as small,
independently-useful PRs (see §8). We are a consumer of the CLI, not a fork.

Precedent for this shape: `mohad12211/twitch-downloader-gui` is a Linux GUI that
lives as its own project and just expects the CLI binary to be present.

---

## 3. Architecture

### 3.1 Runtime shape

The app bundles a self-contained build of `TwitchDownloaderCLI` as a helper
executable and drives it as a subprocess. The Swift layer owns the UI, the task
queue, progress, and cancellation.

```
Oxbow.app/
  Contents/
    MacOS/
      Oxbow                  <- SwiftUI app
      TwitchDownloaderCLI    <- helper (self-contained .NET publish)
      ffmpeg                 <- our own LGPL build
    Resources/
      ...                    <- NO executables here (see §4.2)
```

### 3.2 Mono is dead, don't resurrect it

The original plan involved Mono. That premise is stale — the project targets
modern .NET and publishes macOS binaries. Build with:

```bash
dotnet publish TwitchDownloaderCLI -c Release -r osx-arm64 --self-contained true
```

Publish profiles named `MacOS` and `MacOSArm64` exist in the repo. Verify the
required SDK version against upstream's README at build time; it has been moving.

### 3.3 Do NOT use PublishSingleFile

Single-file .NET extracts native libs to a temp dir at runtime, producing unsigned
copies of code. That forces `disable-library-validation`, which weakens the whole
signing posture. Publish to a directory of files and sign each one instead.

### 3.4 Open architectural question — process wrapper vs. NativeAOT

Not yet decided. Start with (A), keep (B) in view.

**(A) Process wrapper.** `Process` + pipes, parse `[STATUS]` lines off stdout,
`--banner=false`, SIGINT for cancellation. Zero C# changes; tracks upstream
releases nearly free. Downside: stdout scraping is brittle, and ffmpeg becomes a
grandchild process, which complicates cancellation and cleanup.

Known stdout format:
```
[STATUS] - Fetching Video Info [1/5]
[STATUS] - Downloading 100% [2/5]
[STATUS] - Verifying Parts 100% [3/5]
[STATUS] - Combining Parts 100% [4/5]
[STATUS] - Finalizing Video 100% [5/5]
```

**(B) NativeAOT shared library.** A `TwitchDownloaderNative` project wrapping
`TwitchDownloaderCore` with `[UnmanagedCallersOnly]` exports, published with
`-p:NativeLib=Shared`, called from Swift via a C header + module map. Gives real
progress callbacks, real cancellation tokens, structured errors. Signing-wise it's
strictly better: one dylib, no JIT, so no `allow-jit` entitlement and library
validation stays on. Cost: designing and maintaining a C ABI, plus AOT-compat
friction with reflection-heavy dependencies.

(B) is the better long-term artifact and the most upstreamable piece of work.
Pitch it upstream as "a stable C ABI for embedding the core," not as scaffolding
for our Mac app.

### 3.5 UI

SwiftUI, dropping to AppKit where SwiftUI can't express something.

Not UIKit — that's iOS. Not Mac Catalyst either; it produces exactly the
slightly-wrong-feeling app we're trying to avoid.

Rejected: Avalonia. The forms aren't the work — the progress/cancellation/queue
plumbing is, and that gets written either way. Avalonia costs the native feel
without saving the actual labour.

The task queue is the real complexity, not the forms. Design it first.

---

## 4. Distribution

### 4.1 Channel: Developer ID + notarized DMG. Not the App Store.

An Apple Developer Program membership is already paid for. With a Developer ID
signature + notarization + stapling, users get one ordinary "downloaded from the
internet" dialog, not the scary unidentified-developer wall. There is no "untrusted
developer rodeo" to make users suffer through.

**Why not the Mac App Store**, in descending order of risk:

1. **App Review category risk.** Apple has a long history of rejecting media
   downloaders over copyrighted-content concerns. A Twitch VOD downloader sits
   squarely in that category. It's a reviewer judgment call, not something we can
   engineer around, and we could pass at 1.0 and get pulled at 1.4.
2. **FFmpeg licensing.** GPL is generally treated as incompatible with App Store
   terms; LGPL is more defensible but we're bundling an executable, not linking.
3. **No downloading executables.** We're stripping the runtime FFmpeg fetch anyway.
4. **Sandbox plumbing.** Security-scoped bookmarks, and verifying the helper
   inherits file access.

MAS would buy us discovery we won't get much of and update delivery we can solve
for free. Not worth it.

### 4.2 Signing rules

- Helper executables go in `Contents/MacOS/`. **Never** `Contents/Resources/` —
  executable code in a resource location is the classic notarization rejection.
- Sign inside-out: every nested Mach-O first, then the app bundle last.
- Use `--options runtime --timestamp` with the Developer ID Application cert.
  (The Developer ID *Installer* cert is only for `.pkg`; a DMG doesn't need it.)
- **Do not use `codesign --deep`.** Deprecated, silently does the wrong thing.
  Script explicit per-file signing.
- **Xcode gotcha that will cost an afternoon:** automatic signing re-signs the
  embedded helper during Copy Files and clobbers its entitlements. Turn off
  "Code Sign On Copy" for the helper and sign it yourself in a Run Script phase
  that runs *after* embedding.
- Entitlements are per-process. If the helper is CoreCLR-based it needs
  `com.apple.security.cs.allow-jit` (possibly `allow-unsigned-executable-memory`)
  on **its own** signature. The app's entitlements do not propagate to children.

### 4.3 Notarize + package

```bash
create-dmg ... Oxbow.app
xcrun notarytool submit Oxbow.dmg --key AuthKey.p8 --key-id ... --issuer ... --wait
xcrun stapler staple Oxbow.dmg
```

Staple both the `.app` (before packaging) and the `.dmg`. Stapling is what makes
first launch work offline.

**CI:** GitHub Actions macOS runners handle all of this. Store the cert as a
base64 `.p12` + password. Use an App Store Connect API key (`.p8` + key ID +
issuer ID) rather than an app-specific password — cleaner for automation, doesn't
break on Apple ID password rotation. First end-to-end run is a half-day of yak
shaving; after that it's a script.

### 4.4 Homebrew is additive

Once notarized, a cask is ~15 lines pointing at the GitHub release DMG, and gets
`brew upgrade` for free. Casks for notarized apps are trivial; casks for unsigned
apps are a fight. Primary artifact = notarized DMG on GitHub Releases; cask on top.

### 4.5 Updates

Skip Sparkle for 1.0. It has its own signing requirements (XPC services signed
correctly, EdDSA key for the appcast). For v1: check the GitHub releases API on
launch, show an unobtrusive banner linking to the release page. Homebrew users get
`brew upgrade`. Add Sparkle when there are enough non-brew users to justify it.

---

## 5. FFmpeg

**Bundle our own LGPL build** (no `--enable-gpl`, no libx264) and encode with
`h264_videotoolbox`. This dodges GPL obligations entirely *and* hardware-accelerated
chat renders are faster. Correct call even outside the App Store.

Pass `--ffmpeg-path` and `--output-args` explicitly so the CLI never tries to
download anything. The CLI's built-in FFmpeg downloader is a trap: on Apple
Silicon every binary must be at least ad-hoc signed to execute, so a freshly
downloaded FFmpeg won't run without shelling out to `codesign -s -` at runtime.

Architectural note worth adopting regardless: have the CLI always write into the
app container or a temp dir, and let the **parent Swift process** move the finished
file to the user's chosen location. Simplifies the helper's world and makes future
sandboxing painless.

---

## 6. Naming

Working name: **Oxbow** (an oxbow lake is the bend of a river cut off and left
behind while the river moves on — which is what archiving a live broadcast is).

Cursory check done, not blocked but crowded:

- **Trademark: clean.** OXBOW registrations found are archery equipment (Accubow
  LLC) and small-animal feed (Oxbow Enterprises). Also Oxbow Carbon (petcoke) and
  a French surfwear brand. No live US class-9 software registration found.
  *Do a proper TSDR search before printing anything.*
- **Software namespace: busy.** `abdenlab/oxbow` (genomics I/O library) owns the
  obvious GitHub repo name; there's also an OCaml tiling WM for River, Oxbow UI
  (Tailwind components), an ORNL HPC toolkit, and several consultancies.
- **Gotcha:** "oxbow code" is established programmer jargon for *dead code*.
  Obscure, but a subset of the audience will connect it.
- **Not checked:** domain availability. `oxbow.com` is Oxbow Carbon.

**Recommendation:** treat "Oxbow" as the brand plus a searchable qualifier —
product name "Oxbow for Twitch", tagline "Twitch VOD downloader and chat renderer
for macOS", bundle ID `com.<you>.oxbow`. Alternative if the dead-code association
grates: **Sluice** (same water-diversion metaphor, no jargon baggage, likely
emptier namespace — unchecked).

**Trademark hygiene regardless of name:**
- Don't use the Twitch glitch logo. Don't build the app icon or chrome around
  Twitch purple. Trade dress draws more attention than a word in a title.
- "Not affiliated with Twitch Interactive, Inc." in README and About box.
- Attribution to TwitchDownloader (MIT requires the copyright notice anyway).

---

## 7. Scope trims for v1

- **arm64 only.** The project publishes `MacOS` and `MacOSArm64` as separate
  profiles; universal means `lipo`-ing them. Skipping Intel halves the signing
  surface and test matrix. Easy to add later.

### Under consideration: narrowing the intake (2026-08-24)

**Not decided. Recorded so it is not silently re-litigated.**

The intake currently offers three independent toggles — Video, Chat, Render
chat — which compose into every combination the queue can express
(`docs/design/chat-and-render.md` §2). The leaning is to be more opinionated
than upstream and offer roughly two shapes instead: *download the VOD*, and
*download the VOD with its chat rendered alongside* (warned as slow).

The argument: a rendered chat video **in isolation** has little use. It is
interesting next to the video it belongs to, and hardly at all on its own. A
Mac app earns its keep by having a view about what people actually want, where
the CLI's job is to expose every combination. Anyone who genuinely wants a
standalone chat render can run the CLI; that is not a hard thing to do.

The counter-argument, such as it is: the toggles already exist and work, and
narrowing removes capability from people who have not asked for it to be
removed.

Worth noting the cost asymmetry — this direction **deletes** options rather
than adding them, so it stays cheap for as long as nothing is built on top of
the current three-toggle shape. It gets more expensive once the UI grows
around it.

Related, and part of the same thought: **compositing the VOD and the rendered
chat into one video** for offline viewing. Neither upstream CLI nor the WPF app
does this. Measured on an M1 Max with real inputs, a side-by-side composite
runs at **4.79x realtime** with `h264_videotoolbox` — about **75 minutes and
~22 GB for a six-hour stream**. There is no cheaper path: spatial composition
changes every pixel, so a full re-encode is unavoidable. Note also that the
obvious reference implementation uses `libx264`, which we cannot ship.

If that is ever built, one small thing makes it painless and could land
earlier: **default the chat render's framerate to the selected quality's**, so
the two videos line up before anything is composited. The framerate is
derivable from the quality name (`1080p60` → 60). Do **not** take it from the
m3u8's `FRAME-RATE` attribute — it reports a measured average (57.034 on a
60 fps VOD) rather than the container's rate, and matching it would introduce
exactly the drift the change exists to avoid.

---

## 8. Upstream relationship

Licence is MIT, so legally no permission is needed for any of this — fork, ship,
keep the copyright notice. Everything below is etiquette and self-interest (we want
CLI changes upstreamed so we're not maintaining a fork forever).

- **Address ScrubN, not lay295.** ScrubN authored the large majority of merged PRs
  and does most of the triage. Median PR close time is ~1 day, so short focused
  PRs land well.
- **Issue creation appeared to be restricted** on the repo — check Discussions or
  comment on something related instead. Verify current state before drafting.
- **Reach out after a working POC, not before.** "Would you accept a macOS UI?" in
  the abstract gets a shrug. A link to a working thing plus one specific question
  gets a real answer. But don't disappear for three months either.
- **First upstream PR candidate:** machine-readable progress output, e.g.
  `--progress-format json`. Useful to every scripted consumer, not just us, and a
  tight reviewable diff. Currently we'd be scraping `[STATUS]` text.

---

## 9. Immediate next step

**The signing spike. Do this before writing any UI.** This is the exact thing that
stalled the previous attempt, and it's the last genuinely unfamiliar piece.

One afternoon, throwaway:

1. Hello-world .NET console app → `dotnet publish` self-contained, not single-file
2. Drop into `Contents/MacOS/` of an empty SwiftUI app
3. Sign inside-out (helper first with its own entitlements, then bundle)
4. Notarize + staple
5. Download on a clean machine, confirm it launches AND successfully spawns the
   child process

If that loop goes green, everything after it is ordinary app work. If it doesn't,
we learn why now instead of after building a UI.

After that: task queue design, then the CLI wrapper, then forms.

---

## 10. Verify before relying on

Several facts here came from web search on 2026-08-23 and may have moved:

- Upstream's required .NET SDK version and publish profile names
- Whether issue creation is still restricted on the repo
- Exact entitlements needed for a CoreCLR helper under hardened runtime — test,
  don't assume
- Trademark and domain availability for the chosen name
