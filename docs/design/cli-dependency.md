# Is the bundled CLI carrying its weight?

**Status:** decided 2026-08-27 — **keep it**, with two cheap changes that were
found while asking.

`docs/development.md` "Do not suggest" has always ended with *"Reimplementing
chat render in Swift. That's the one part genuinely worth keeping in C#."* That
was an assertion. This document is the evidence, written when the decision was
reopened deliberately rather than by accident.

Everything here was measured on 2026-08-27 against the vendored submodule at
`d4122d8` (upstream 1.56.5) and the real helper. Where something is unverified
it says so.

---

## 1. The question, and why it was reopened

Oxbow started as a Mac front end for `TwitchDownloaderCLI`. Since then the app
has grown a queue engine, a compositing step that upstream does not have, and a
geometry model with opinions of its own — and the helper became the largest
single thing in the bundle without anyone deciding it should be.

The reopening argument, in the maintainer's words: *what is embedding it
actually buying us?* With a specific sub-claim — that the chat render's visual
fidelity is mid-tier, that a Swift reimplementation of text, timestamps and
emoji is close to trivial, and that rendering during the composite would remove
a whole pre-render step.

Four premises. Three of them do not survive measurement, and the fourth points
the opposite way from how it reads.

## 2. Upstream is not dying, but its rhythm is not what §8 says

The immediate trigger was an upstream PR sitting unaddressed for four days
against `architecture.md` §8's claim that *"median PR close time is ~1 day."*

**That claim is what is wrong**, not the project. It was measured during a burst
and recorded as a constant. The real shape, from the submodule's own history:

| Dormant stretch | Length | How it ended |
|---|---|---|
| 2025-08-22 -> 2025-11-10 | 80 days | burst |
| 2025-11-10 -> 2026-02-02 | 84 days | burst |
| 2026-02-04 -> 2026-06-07 | **122 days** | burst — ~40 commits across Jun-Aug 2026 |

Eleven distinct contributors in 2026. The last commit before the pin is
2026-08-16. A four-day-old PR is inside the noise floor of a project that has
gone quiet for four months twice in the last year and come back both times.

The recent work is not maintenance-mode either: `New m3u8 API + support vertical
VODs`, `Migrate to 7TV emote-set API endpoint`, `Update clip info API`, `Up to
80% faster chat rendering`, `3x faster mask rendering`, `New, more accurate
dispersion algorithm`.

**Fix `architecture.md` §8 regardless of this decision.** Expect bursts
separated by months, and do not read silence as death.

## 3. The churn we are outsourcing

`git log --since=2025-06-01 -- TwitchHelper.cs TwitchObjects/Gql Models/M3U8*.cs`
returns **22 commits in 14 months**. A sample of what is in there:

- three separate `update ... query hash` commits — Twitch's GQL persisted-query
  hashes rotate, and somebody has to notice
- `Handle third-party emote provider outages`
- `Fix NRE crash when emote provider throws on fetching metadata`
- `Fix emote cache to use Id instead of Name`
- `Bypass 2k/4k quality login requirements`
- `Migrate to 7TV emote-set API endpoint`

Third-party emote-provider churn was raised as the scary part of going native.
It is — and right now it lands on somebody else, twenty-two times, while we
build a signing pipeline.

## 4. What the render actually is

The render was described as text, timestamps, emoji, with animated emotes as the
only real lift. `ChatRenderer.cs` is **2,322 lines**, backed by roughly 1,100
more in `TwitchHelper` for asset fetching and caching. Beyond that description it
handles:

- comment-offset **dispersion** and jitter (see §7)
- six highlight message types — subscribe, gift, bits-tier, watch-streak,
  charity donation — each with its own layout and icon
- cheermotes, tiered by bit amount
- animated-emote frame indexing with a validity cache
- **ZWJ emoji sequence splitting**, against Unicode 17 tables
- **RTL shaping through HarfBuzz**, with separate RTL text measurement
- per-glyph font fallback for glyphs no font in the stack has
- **WCAG contrast adjustment** of username colours against the background
- alpha-mask generation for transparent renders
- width-aware wrapping with delimiter rules, badge filtering by bitmask

Plus ~19 MB of embedded emoji graphics (Noto 2.051 and Twemoji 17.0.3) and
3.4 MB of Inter, both inside `TwitchDownloaderCore.dll`.

"Mid-tier" may be a fair verdict on the *output*. It is not one on the *code*,
and the gap between those two is the whole of §7.

## 5. Rendering during the composite saves nothing. This was already measured.

The strongest-sounding argument — fold the render into the composite and delete a
step — is closed, by our own spike, in
[`docs/composite-performance.md`](../composite-performance.md) §4.1, dated
2026-08-26:

| | |
|---|---|
| Baseline (chat as an intermediate H.264 file) | 48.4s |
| Chat as raw `yuv420p` over a pipe | **48.4s** |
| Chat as raw `bgra` over a pipe | **48.5s** |

Zero, in both pixel formats. The composite is bound by `h264_videotoolbox` at
~800 Mpx/s of output pixels and a single FFmpeg process already extracts 94% of
it; the 12.6s of chat decode a fused render removes was never on the critical
path.

End to end it is worse than it looks. `compositing.md` §6's realised timeline is
`chat + max(video 9, render 14) + composite 74`, so removing the render entirely
yields **1.06x — about five minutes on an 88-minute job** — because the render
is nearly hidden behind the video download already.

**So "render during compositing" is not an argument for a native renderer.** It
is an argument for a FIFO, which needs no rewrite, and which was priced at that
same 1.06x plus **10.2 GB off the disk peak** and rejected on coupling grounds.
If the disk peak is the motivation, reopen the FIFO — not the renderer.

## 6. The ledger, and the asymmetry inside it

### What it costs today

- **126 MB, 204 files**, of which 15 are native dylibs and 183 managed
  assemblies — every Mach-O signed individually, all of it notarization surface
- the **.NET 10 SDK** as a build dependency. Well contained: `ci.yml` needs none
  of it and `CONTRIBUTING.md`'s promise that most changes need only `swift test`
  holds
- **`com.apple.security.cs.allow-jit`** on the helper's own signature
- **~390 lines of pure boundary tax** — `StatusLineParser` (128), `StepPhases`
  (132), `OutputDialect` (48), `FailureInterpreter` (82) — Swift that exists
  only because the boundary is a pipe, plus `VideoInfoFetcher` (126) and most of
  `ArgumentBuilder` (177)
- the traps already paid for: the collision-prompt hang (upstream PR #1644),
  `--flag=false` reading as true, `-q`'s silent fallback to best, `--output-args`
  rejecting the space-separated form

### What it buys, verb by verb

| Verb | What it actually is | Cost to replace |
|---|---|---|
| `info` | two GQL calls. **We already parse its raw output ourselves** — `VideoInfo.swift` is 477 lines of exactly that | ~free |
| `chatdownload` | 688 lines: GQL comment pagination, offset adjustment, user backfill, optional image embedding | days |
| `clipdownload` | 202 lines: three GQL calls and an MP4 fetch | days |
| `videodownload` | 720 lines, plus `M3U8Parse` (687), `M3U8` (435), `VideoDownloadThread` (201). Parallel download threads with restart limits, part verification, invalid-part detection, **hand-written MPEG-TS null packets to stub missing parts**, AV1 header handling, muted-segment regex, storage preflight, ffmpeg concat lists with stream ids, and a **community proxy fallback** (`twitch-downloader-proxy.twitcharchives.workers.dev`) for sub-only and restricted VODs | weeks — and the code is the easy half. The field knowledge about how Twitch's CDN misbehaves is the hard half |
| `chatrender` | §4 | months to parity |

### The asymmetry

Size and difficulty point in opposite directions from where intuition puts them.

The **download** verbs are the cheap ones to replace — and replacing them buys
**zero megabytes**, because the entire .NET runtime would still ship for
`chatrender`. The only cut that removes the weight is the **render**, which is
the expensive, highest-churn, most actively-optimised part of the codebase.

There is no cheap partial exit. It is all or nothing, and "all" starts at the
hard end.

## 7. The fidelity complaint is a flags problem

`ArgumentBuilder.renderChat` emits exactly three optional switches:
`--alternate-backgrounds`, `--timestamp`, `--outline`. Everything else runs on
the CLI's defaults. Not passed, all of them default-false and therefore fully
expressible as bare flags:

- **`--dispersion`** — *"In November 2022 a Twitch API change made chat messages
  download only in whole seconds. This option uses additional metadata to attempt
  to restore messages to when they were actually sent."* Without it, every
  message in our renders lands on a whole-second boundary and clumps. It requires
  `--update-rate < 1.0`; the default is 0.2, so the requirement is already met and
  the flag alone is enough. Upstream shipped a rewritten dispersion algorithm on
  2026-08-01 (#1636), which **is** in the pinned commit.
- **`--avatars`** — user avatars beside username and badges, supported since #1453
- `--scale-emote`, `--username-fontstyle`, `--message-fontstyle`, `--badge-filter`

If chat that ticks robotically in one-second clumps is a meaningful part of
"mid-tier at best", that is a one-line change, not a subsystem. **Try the flags
before concluding anything about Skia.**

Unmeasured, and deliberately not claimed: whether `--dispersion` visibly improves
our composite renders, and what it costs. Measure it against decoded output, per
`twitch-metadata.md` §7.

## 8. Trimming the publish — 126 MB to 67 MB

`docs/development.md` forbids upstream's `MacOSArm64` publish profile, correctly,
because it sets `PublishSingleFile`. But it lumps `PublishTrimmed` in with it,
and **those two flags are independent.**

Upstream ships trimmed on macOS and has since 2026-02-04, when #1561 added
`JsonSerializerIsReflectionEnabledByDefault=true` to every publish profile as
the mitigation for reflection-based JSON.

Published with trim **on** and single-file **off**:

| | current | trimmed |
|---|---|---|
| Size | 126 MB | **67 MB** |
| Files | 204 | **85** |
| Native dylibs | 15 | **15** — untouched |
| Managed assemblies | 183 | **64** |
| `TwitchDownloaderCore.dll` (embedded emoji + fonts) | 23.7 MB | 23.7 MB — preserved |

### What trimming removes, and what it cannot

ILLink walks the call graph statically from the entry point and deletes what
nothing reaches. With `TrimMode=partial` that happens at two granularities, and
both fired here:

- **Whole assemblies**, where nothing in them is reachable at all:
  `System.Private.Xml` (8.6 MB), `System.Linq.Expressions` (4.4),
  `System.Data.Common` (3.1), `System.Private.DataContractSerialization` (2.3),
  `Microsoft.VisualBasic.Core` (1.3), `System.Linq.Parallel`, `Microsoft.CSharp`
  — 119 of them, shipped only because "self-contained" means the whole framework
  by default.
- **Members inside assemblies marked trimmable**, which the BCL is and
  third-party packages generally are not. `System.Private.CoreLib.dll` goes
  **16.3 MB -> 2.8 MB**: same assembly, 83% of it unreachable.

Nothing native is trimmed, so the signing model is unchanged: still a directory
of individually signed Mach-O files, still no `disable-library-validation`.

**There is no third round of this.** What remains is mostly not code:

| Remaining 67 MB | |
|---|---|
| `TwitchDownloaderCore.dll` | 23.7 MB, of which ~19 MB is the embedded Noto and Twemoji archives |
| Native dylibs — Skia 14.4, CoreCLR 5.9, clrjit 3.0, HarfBuzz 2.7, and eleven more | ~32 MB, untrimmable |
| All remaining managed code | ~11 MB |

The floor is emoji graphics plus Skia plus the CLR. Trimming got what was
gettable.

**Why this is a runtime risk and not a build-time one.** Static analysis cannot
see reflection. `JsonSerializer.Deserialize<T>` resolves types at runtime, so the
linker can delete a model type it cannot prove is used, and the failure surfaces
as an exception in the field rather than an error in CI. That is what every
IL2026 warning below is saying, and it is why `info` succeeding proves less than
it appears to.

**`PublishSingleFile` stays forbidden.** `architecture.md` §3.3 is unaffected by
any of this — single-file extracts native libraries to a temp directory at
runtime, producing unsigned copies of executable code. Trim is the win; single
file is still the trap.

**Verified so far:** the trimmed helper launches, reports
`1.56.5+d4122d80214b08b3c7078003aae43088e601a435`, and `info --banner=false --id
1480816483 --format Raw` returns correct JSON at exit 0 — which exercises the
reflection-heavy `ReadFromJsonAsync` path that ILLink warns about (IL2026).

**NOT verified:** `chatdownload`, `chatrender`, `videodownload` on a trimmed
build. ILLink emits IL2026 warnings across all three, including
`ChatJson.SerializeAsync`, `RefreshOrLoadProviderMetadata`,
`M3U8Extensions.WithUnavailableMedia` and
`JsonElementExtensions.DeserializeFirstAndLastFromList`. Trim warnings are not
trim failures, but per `twitch-metadata.md` §7 this needs a full job run against
decoded output before it goes near `full-build.yml`. **Do not adopt on the
strength of this table alone.**

## 9. The decision

**Keep the bundled CLI.**

Not from inertia. Replacing it means taking on the highest-churn code in the
project — 22 API breakages in 14 months, currently absorbed by someone else —
and reimplementing 2,322 lines of accumulated correctness, to chase a speed win
our own measurements put at 1.06x, with **no size relief at all** until the
hardest part is finished.

The real exposure was never "upstream might die". It is "upstream might be
dormant when something big breaks", and the insurance for that is already in
place and already paid for: MIT licence, vendored submodule, pinned commit. We
can write the patch and carry it. That is a materially different position from
depending on a published binary.

### What changes the answer

- Twitch ships a breaking change during a dormant stretch and we are blocked more
  than two weeks with no upstream response to a patch we have already written.
- .NET 10 or SkiaSharp breaks on a macOS release and the fix is not ours to make.
- **The product moves somewhere the CLI cannot follow — a live overlay, a
  scrubbable chat, an in-app preview.** This is the likely one. Everything
  differentiated about Oxbow — compositing, `CompositeGeometry`, fragmented
  output — is already ours, in FFmpeg. The CLI is plumbing, not identity. If the
  product grows a real-time chat surface, a native renderer stops being a rewrite
  and becomes a new feature that happens to obsolete the old path. That is the
  version of this instinct worth betting on, and it is a product decision, not an
  architecture one.

### Consequent changes

1. `architecture.md` §8 — correct the "median ~1 day" PR claim (§2 above).
2. `development.md` — stop conflating `PublishTrimmed` with `PublishSingleFile`
   (§8 above).
3. Try `--dispersion` and `--avatars` before touching anything structural (§7).
4. Trim the publish once §8's untested verbs are verified end to end.

## 10. Reproducing this

Upstream health, from the submodule:

```bash
git -C vendor/TwitchDownloader log --format='%ad' --date=format:'%Y-%m' | sort | uniq -c
git -C vendor/TwitchDownloader log --since=2025-06-01 --oneline -- \
  TwitchDownloaderCore/TwitchHelper.cs \
  TwitchDownloaderCore/TwitchObjects/Gql \
  'TwitchDownloaderCore/Models/M3U8*.cs'
```

The trimmed publish. Note `PublishSingleFile=false` — it is the point:

```bash
dotnet publish vendor/TwitchDownloader/TwitchDownloaderCLI -c Release -r osx-arm64 \
  --self-contained true \
  -p:PublishSingleFile=false \
  -p:PublishTrimmed=true -p:TrimMode=partial \
  -p:JsonSerializerIsReflectionEnabledByDefault=true \
  -p:PublishReadyToRun=false -p:DebugType=none \
  -o /tmp/helper-trimmed
```

The FIFO and encoder-ceiling numbers in §5 are not reproduced here — see
`docs/composite-performance.md` §8, which carries its own reproduction and the
formula that predicts any job from one measurement.
