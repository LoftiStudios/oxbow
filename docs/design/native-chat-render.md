# Native chat render — design

**Status:** draft 2026-09-17, for reading. **Not approved, not scheduled.** It
does not reverse [`cli-dependency.md`](cli-dependency.md) §9 on its own; it
describes what the work would be if that decision is reopened, and how to stop
partway without leaving anything behind.

Related: [`cli-dependency.md`](cli-dependency.md) (the decision this would
revisit), [`../composite-performance.md`](../composite-performance.md) §4.1 (the
pipe spike), [`resume.md`](resume.md) §12 (the chat render's own seek),
[`chat-and-render.md`](chat-and-render.md) §7 (render options).

Source references are to the vendored submodule at `d4122d8` (upstream 1.56.5).

---

## 1. Why this is on the table

Two open upstream PRs (#1644, #1646) have had no maintainer response for a
month. By itself that is not new information — `cli-dependency.md` §2 records
dormant stretches of 80, 84 and 122 days, and says not to read silence as
death. The motivation here is different:

- **§9's third trigger** — *"the product moves somewhere the CLI cannot
  follow"* — is the likeliest reason Oxbow ever leaves the CLI, and a native
  renderer is the precondition for all of it (in-app preview, scrubbable chat,
  a live overlay).
- **The ordering in this document makes it cheap to abandon.** That is the
  new argument, and §2 is about it.

## 2. Order by cost to abandon, not cost to replace

`cli-dependency.md` §6 ranked the verbs by what they cost to *replace*, and
concluded the render is the last thing to touch. For an experiment the useful
ranking is what each costs to *walk away from* halfway through:

| Start with | Touches | If abandoned halfway |
|---|---|---|
| `info` | intake, `VideoInfoFetcher`, every job's metadata | a half-migrated data path in the hottest part of the app |
| `chatdownload` | the job graph, resume, `StepPhases`, the JSON every render reads | two producers of the same file, one of them unfinished |
| `videodownload` | the largest step, disk preflight, resume | the most dangerous thing to leave half-done |
| **`chatrender`** | **one step: a JSON file in, a video file out** | **delete a module and a hidden setting** |

The render has the smallest surface of any verb. Its input is a file on disk
the CLI already writes; its output is a file the composite already reads. If
the native renderer produces the same file, nothing downstream can tell which
one ran — and nothing upstream changes at all.

It is also the only verb with a **built-in reference implementation** sitting
in the bundle: same JSON, same geometry, render it both ways and compare (§8).

**What it does not buy, stated plainly:** zero megabytes. The .NET runtime
still ships for `chatdownload`, `videodownload` and `info`. Size relief comes
only after every verb is gone, and this document does not propose that.

## 3. The boundary

### In: TwitchDownloader's chat JSON, with images embedded

The CLI keeps downloading chat. The native renderer reads `ChatRoot`
(`TwitchObjects/ChatRoot.cs`): `streamer`, `video`, `comments`, and
`embeddedData` — `firstParty`, `thirdParty`, `twitchBadges`, `twitchBits`. The
file carries its own schema version (`FileInfo.Version`, currently 1.4.0),
which the decoder should check and refuse on an unknown major.

**Today the renderer is not offline.** `ChatRequest.isEmbeddingImages`
defaults to `false`, so `-E` is not passed, and `chatrender` fetches badges,
cheermotes and 7TV/BTTV/FFZ emotes over the network at render time
(`TwitchHelper.GetThirdPartyEmotes`, `GetEmotes` — both use `embeddedData` when
present and fetch otherwise). That fetching is where the churn in
`cli-dependency.md` §3 lives: the 7TV endpoint migration, provider outages, the
emote cache bugs.

So the first change, before any renderer code: **pass `-E` for every job that
renders.** Then the native renderer never touches the network. Its only
dependency is a file format, and the provider churn stays inside the CLI's
download step, where it already is.

Unmeasured: how much `-E` grows the JSON on a heavy-chat VOD, and how much time
it adds to the download. Measure both on `2856361990` before adopting.

Not embedded, and therefore out of scope: avatars (`--avatars`, still untried
per `cli-dependency.md` §7).

### Out: exactly what `chatrender` produces today

The composite's filter graph (`ArgumentBuilder`, `.composite`) takes input 1 as
an H.264 file and `hstack`s it beside the video, relying on
`eof_action=repeat` to hold the last chat frame. The native renderer's first
output is that file, byte-for-byte in shape:

- `width` × `height` from `RenderRequest`, `framerate` CFR
- raw frames piped to our FFmpeg, encoded with `-c:v h264_videotoolbox -b:v
  {bitrateMbps}M -pix_fmt yuv420p` — the same `--output-args` we pass today
- `unsharp=5:5:1.0` when `isSharpened`, as an FFmpeg filter, unchanged
- the same duration rule: the render ends at the last message, not at the end
  of the video (this is what `resume.md` §12 depends on)

No mask output. Oxbow never asks for one.

## 4. Architecture

### The frame at time *t*, not a render loop

The CLI's renderer is a loop: `RenderVideoSection` walks ticks in order and
`GenerateUpdateFrame` builds each update from the previous one. The native one
is built around a single function instead:

```swift
protocol ChatFrameSource {
  var size: CGSize { get }
  var duration: Duration { get }
  func frame(at time: Duration) -> CVPixelBuffer
}
```

This is less of a departure than it looks. `GenerateUpdateFrame` already draws
bottom-up: it finds the newest comment visible at the current time, then walks
backwards drawing pre-rendered comment sections until the frame is full
(`ChatRenderer.cs:760`), and it already skips to 100 comments before the start
when it begins partway through. The state it carries between ticks is a cache,
not a dependency. So random access costs a binary search plus a walk back over
precomputed heights.

Random access is what makes the rest of this document possible: resume from any
time (§7), render-during-composite (§7), and any in-app preview later.

### Pieces

All in `OxbowKit`, so all of it except the final encode runs under `swift test`
with no .NET and no FFmpeg.

| Piece | Does | Testable as |
|---|---|---|
| `ChatDocument` | `Codable` decode of the fields we use from `ChatRoot` | fixtures |
| `ChatTimeline` | dispersion, update-rate flooring, "newest comment at *t*" | pure functions over offsets |
| `ChatAssets` | decode embedded images with ImageIO; animated frame index by time | fixtures |
| `MessageLayout` | a comment → badges, username, message runs, wrapped at width → a height and draw list | pure, given a font |
| `ChatRasterizer` | draw the visible sections for *t* into a `CGContext` | image snapshots |
| `FileSink` | drive `frame(at:)` over the duration, pipe raw frames to FFmpeg | integration only |

### Porting notes from `ChatRenderer.cs`

- **Dispersion** (`DisperseCommentOffsets`, line 208) re-derives offsets from
  `created_at` when the drift between estimates is under 1.5s, and otherwise
  falls back to `JitterCommentOffsets`, which is **seeded** —
  `new Random(comments.Count)` — so the CLI's output is deterministic. Ours
  must be too, but will not reproduce .NET's `Random` sequence, so jittered
  offsets will differ from the CLI's. The `created_at` path should match
  exactly; the fallback should match in distribution only.
- **Update rate.** Positions change only on update ticks (default 0.2s,
  `FloorCommentOffsets`); animated emotes are composited onto the held update
  frame every tick (`ComposeAnimatedFrame`). Keep both behaviours — the first
  is what the dispersion measurements in `cli-dependency.md` §7 were taken
  against.
- **No scroll animation.** Chat jumps at update ticks. Do not add easing in
  this work; that is a visible change the frame comparison cannot judge.
- Porting logic from MIT-licensed C# is fine with attribution; keep the
  upstream copyright notice in the file header of anything substantially
  derived.

## 5. Scope: what "done" means

Written down before starting, so the finish line cannot drift.
`ChatRenderer.cs` is 2,322 lines; this list, not that number, is parity.

### Must match the CLI

- message text, wrapping at width with the CLI's delimiter rules
- username colours, including the contrast adjustment against the background
- badges (the CLI's default set — `--badges` is on and cannot be turned off
  through the CLI today, `chat-and-render.md` §7)
- first-party and third-party emotes, static and animated
- cheermotes, tiered by bit amount
- emoji
- the six highlight message types (`--sub-messages` is likewise always on)
- `RenderRequest`'s appearance fields: font size, font, background, alternate
  backgrounds and colour, message colour, timestamps, outline and outline size
- dispersion, always on
- the duration rule in §3

### Expected to come from the platform — verify, do not assume

The parts of §4 of `cli-dependency.md` that were hand-built for Skia are, on
macOS, Core Text's job: RTL shaping and bidi, per-glyph font fallback, ZWJ
emoji sequences. That is the biggest reason this is smaller than 2,322 lines
suggests, and **none of it has been tested here.** Phase 1 must include an RTL
message, a ZWJ family emoji and a CJK fallback in its fixtures.

ImageIO is expected to decode animated GIF and WebP. Also unverified.

### Accepted differences

- **Emoji look like Apple Color Emoji**, not Noto/Twemoji. Visible, and fine.
- **Font rendering will not be pixel-identical** to Skia's. §8 compares
  structure, not pixels, for this reason.
- **The default font.** `RenderRequest.font` defaults to `"Inter Embedded"`,
  which lives inside `TwitchDownloaderCore.dll`. Either bundle Inter (OFL) or
  change the default to the system font — an open question, §10.

### Out of scope

Avatars, mask output, `--scale-emote`, font style options, badge filtering,
ignore lists and banned words — none of which Oxbow exposes today.

## 6. Phases, and where each one can stop

Every phase ends at a clean stopping point. **Abandoning at any of them means
deleting the renderer module and its hidden setting; nothing else in the app
has changed.**

### Phase 0 — prerequisites, no renderer code

1. Pass `-E` for rendering jobs; measure JSON size and download time (§3).
   Worth doing even if the renderer is never built — it takes network fetching
   out of the render step.
2. Build the comparison harness (§8) against the CLI alone, so it is known to
   work before there is anything to compare.
3. Amend `development.md`'s "Do not suggest" entry and `cli-dependency.md` §9
   with a pointer here, so the experiment is not argued against as a mistake.
4. Set the time budget (§10).

### Phase 1 — timeline and text

`ChatDocument`, `ChatTimeline`, `MessageLayout` for plain text, a rasterizer,
and `FileSink`. Behind a hidden setting, off by default.

**Stop if:** message appearance times or line wrapping do not match the CLI
within tolerance (§8) on both reference VODs, or Core Text does not handle the
RTL/ZWJ/fallback fixtures without hand-rolled workarounds. Either one means the
cheap part of the estimate was wrong.

### Phase 2 — everything else in §5

Badges, emotes, cheermotes, highlight types, appearance options.

**Stop if:** the budget is spent. This is the phase most at risk of sitting at
90% for weeks. Check the budget, not the remaining list.

### Phase 3 — make it the default

Setting defaults on; the CLI render path stays in the codebase for one
release, selectable, then is deleted along with the `chatrender` half of
`ArgumentBuilder`, `StepPhases` and `StatusLineParser`.

### Phase 4 — render during the composite

A separate decision, with its own gate. §7.

## 7. Rendering during the composite

### Why the old answer changes

The composite pipe was measured and rejected in `composite-performance.md` §4.1
— raw chat frames piped in ran in **48.4s, identical to the chat file** —
because the composite is bound by `h264_videotoolbox` encoding the output
(~800 Mpx/s), not by decoding chat. It was rejected **for coupling two
processes**: the CLI and FFmpeg, a FIFO to clean up, two failure modes.

A native renderer removes that objection. The frame source is our code, in our
process, writing into an FFmpeg we already launch and supervise. What the spike
said a pipe would buy is still true:

- **10.2 GB off the disk peak** on a six-hour job — the chat intermediate no
  longer exists
- **the chat column encoded once**, from clean frames, instead of twice.
  [`composite-quality.md`](composite-quality.md) says that column already loses
  on bitrate against the game video
- **`resume.md` §12 goes away.** A render shorter than its video, seeked past
  its own end, yields zero frames; that is why the chat seek is clamped
  separately today. `frame(at:)` past the last message just returns the held
  last frame.

### What it costs

- **Parallelism.** Today the render runs while the video downloads:
  `chat + max(video 9, render 14) + composite 74` minutes. Folded in, render
  work moves onto the composite. That adds nothing *only if the renderer
  produces frames faster than the encoder consumes them.* For the
  `1480816483` geometry (output 2166×1026 ≈ 2.2 Mpx), 800 Mpx/s is roughly
  **360 frames/s** — derived, not measured.
- **Failure coupling.** A renderer crash kills the composite piece. With
  `resume.md`'s pieces, that costs one piece, not the job.
- **Layout changes.** Changing geometry means re-rendering chat, not reusing a
  file. The composite reruns in that case anyway.

### The gate

Before Phase 4 starts: run `frame(at:)` over a whole heavy-chat VOD into a sink
that discards frames, and compare frames/s against the composite's measured
rate on the same machine. Below it, stop: Phase 3's file output is the
finished product, and it is a good one.

## 8. Verification: the CLI as oracle

Pixel equality is not the bar (§5). Three comparisons, all run locally against
the bundled helper, none in `ci.yml`:

1. **Update events.** Detect frames where the chat column visibly changes —
   the method `cli-dependency.md` §7 used to measure dispersion — and compare
   the two event lists. On the `created_at` dispersion path they should agree
   to within one update tick.
2. **Layout.** At fixed times, compare per-message section heights and line
   counts. Wrapping disagreements show up here before they are visible.
3. **Filmstrips, for a person.** Side-by-side frames across the densest second
   (the fifteen-message second in `2856361990` at 2:30:00) and across
   animated emotes. Judged by eye.

Reference inputs: `2856361990` from 2:30:00 for 180s (1,253 messages, heavy),
and `1480816483` (the composite-performance job).

Unit tests for `ChatTimeline` and `MessageLayout` run under `swift test` like
the rest of `OxbowKit`, and need no helper.

## 9. Risks and unknowns

All unverified unless stated.

- **Core Text parity** for RTL, ZWJ and fallback — the premise that makes this
  smaller than it looks.
- **Renderer throughput** — gates Phase 4 only; Phase 3 does not care.
- **`-E` payload size** on heavy chat.
- **Schema drift.** The chat JSON is upstream's format. It is versioned and has
  moved slowly (1.4.0), but a native renderer ties us to it for as long as
  the CLI downloads chat.
- **The jitter fallback** will differ from the CLI's output (§4), so the
  comparison harness needs a VOD on each dispersion path.
- **ImageIO** decoding animated WebP from 7TV.

## 10. Open questions

1. **What is the time budget, and what happens when it runs out?** The whole
   design depends on actually stopping.
2. **Bundle Inter, or switch the default to the system font?**
3. **Is Phase 0's `-E` change worth shipping on its own**, regardless of
   whether the renderer is built?
4. **Does Phase 3 need a user-visible choice** during its one release, or is a
   hidden default enough?

## 11. Not in scope

- Replacing `chatdownload`, `info`, `clipdownload` or `videodownload`.
- Any change to how the chat column looks beyond §5's accepted differences.
- An in-app chat preview. `frame(at:)` makes it possible; this document does
  not build it.
- Removing the .NET runtime from the bundle.
