# Native chat render — design

**Status:** draft 2026-09-17, for reading. **Not approved, not scheduled.**
Phase 0's first two items were measured the same day — §3.1 (what embedding
costs) and §8.1 (whether the CLI can be trusted as a reference). It
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

Not embedded, and therefore out of scope: avatars (`--avatars`, still untried
per `cli-dependency.md` §7).

### 3.1 What `-E` costs — measured 2026-09-17

Against the bundled helper and the real VODs. `2856361990` is 7:37:20 of
Just Chatting at ~418 messages/minute; `1480816483` is the 9-minute VOD the
composite-performance numbers were taken on.

| Input | Plain | With `-E` | Download, plain → `-E` |
|---|---|---|---|
| `1480816483`, 93 comments | 73 KB | 974 KB | 0.7s → 12s (cold) |
| `2856361990` @ 2:30:00 +180s, 1,250 comments | 0.86 MB | 17.7 MB | 1.8s → 122s cold, 23s warm |
| `2856361990` @ 2:30:00 +30min, 10,195 comments | 7.1 MB | 48.2 MB | 11s → 141s cold, 84s warm |
| `2856361990` entire, 179,726 comments | 126 MB | **256 MB** | 153s → **784s cold, 355s warm** |

Size tracks the number of *distinct* emotes, not the number of messages: the
3-minute window embeds 98 third-party emotes (15.4 MB of its 17.7 MB), the
whole VOD 710. The extra 130 MB on the full VOD is base64, so ~97 MB of image
data.

**The fetch is moved, not added.** Today's render step does the same fetching,
because a plain JSON gives it nothing to work from. Same window, empty cache
both times, production encoder:

| Render | |
|---|---|
| plain JSON, CLI fetches while rendering (today) | **107s** |
| embedded JSON, `--offline` | **23s** |

So `-E`'s ~100s on the download buys ~84s back on the render, and the render
stops depending on the network. What is genuinely new is the larger
intermediate file.

**Every job pays the cold price.** `StepContextBuilder` gives each step of each
job a fresh `--temp-path` (`workspace.prepareStep(job:step:)`), and the CLI's
emote cache lives inside it, so nothing is ever reused between jobs. A cache
directory shared across jobs would roughly halve the embed cost (784s → 355s
on the full VOD); see §10.

**What the warm 355s is, since it is not the network and not serialisation.**
Writing the 256 MB file takes 0.1s. With every emote already cached and zero
downloads, the 30-minute window still spends **57s** loading 240 cached 7TV
emotes, because `TwitchEmote`'s constructor decodes every frame of every
animated emote into `SKBitmap`s (`TwitchObjects/TwitchEmote.cs:34`,
`ExtractFrames`) — work the embedding path never uses, since it only base64s
`ImageData`. Upstream candidate, §9.1.

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
- **Colours for users who never set one** will not match the CLI, because the
  CLI's own choice is not stable between runs (§8.1). 170 of 1,250 messages in
  the reference window have `user_color: null`. Ours picks from the same
  fifteen defaults with a *stable* hash, so a given user keeps one colour
  forever — which is what upstream intends and fails to do.

### Out of scope

Avatars, mask output, `--scale-emote`, font style options, badge filtering,
ignore lists and banned words — none of which Oxbow exposes today.

## 6. Phases, and where each one can stop

Every phase ends at a clean stopping point. **Abandoning at any of them means
deleting the renderer module and its hidden setting; nothing else in the app
has changed.**

### Phase 0 — prerequisites, no renderer code

1. Pass `-E` for rendering jobs, and `--offline` to the render. **Measured
   2026-09-17, §3.1** — the cost is a bigger intermediate file, not extra
   fetching, and the render gets 4.5x faster and stops needing the network.
   Still a decision, not a conclusion: §10.
2. Build the comparison harness (§8) against the CLI alone, so it is known to
   work before there is anything to compare. **Done 2026-09-17 in outline** —
   the CLI-against-itself runs in §8.1 are exactly this, and they found the two
   corrections that make the oracle trustworthy. What remains is packaging them
   as a script beside `bench-composite.sh`.
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

Reference inputs: `2856361990` from 2:30:00 for 180s (1,250 messages, heavy),
and `1480816483` (the composite-performance job).

Unit tests for `ChatTimeline` and `MessageLayout` run under `swift test` like
the rest of `OxbowKit`, and need no helper.

### 8.1 The oracle is sound, but only after two corrections — measured 2026-09-17

Both were found by running the CLI against *itself*, before writing any Swift.
Do that first whenever this harness is rebuilt.

**A chat download is not reproducible.** Two downloads of the same window
return the same 1,250 messages, but 4–8 pairs swap places. Those pairs share a
`content_offset_seconds` **and** a `created_at` to the millisecond (two
messages both at `2026-08-25T23:30:16.964Z`), and `CommentOffsetComparer`
returns `1` for both orderings of such a pair — deliberately, with a comment
that returning `0` would make the sorter drop one. Input order comes from
parallel section downloads merged through a `HashSet`, so it varies. Twitch
creates the tie; the CLI breaks it arbitrarily.

Invisible on screen — two messages in the same millisecond swap — but it means
**every comparison must render from one saved JSON**, never from two
downloads.

**A render is not reproducible at all until username colours are pinned.** Same
JSON, rendered twice, losslessly (`-c:v ffv1 -pix_fmt bgra`), compared by
per-frame hash: **5,322 of 5,400 frames differ**, mean RGB MSE 67.6. Every
difference is a username colour. A comment with `user_color: null` is drawn in
`DefaultUsernameColors[Math.Abs(display_name.GetHashCode()) % 15]`
(`ChatRenderer.cs:1739`), and .NET randomises string hashes per process, so the
same viewer gets a different colour in every render. Upstream candidate, §9.1.

With every `null` colour replaced by a fixed value in the input JSON, on the
same window:

| Comparison | Frames differing of 5,400 |
|---|---|
| same JSON rendered twice, lossless | **0** |
| embedded + `--offline` vs plain + online fetch | **0** |
| `h264_videotoolbox` encoded twice, decoded frames | **0** (file bytes differ) |

So: the harness pins colours in its fixtures, and layout, emotes, dispersion
and timing are all exactly repeatable. The second row is the one that matters
for §3 — embedding changes nothing about the output.

## 9. Risks and unknowns

All unverified unless stated.

- **Core Text parity** for RTL, ZWJ and fallback — the premise that makes this
  smaller than it looks.
- **Renderer throughput** — gates Phase 4 only; Phase 3 does not care.
- **Schema drift.** The chat JSON is upstream's format. It is versioned and has
  moved slowly (1.4.0), but a native renderer ties us to it for as long as
  the CLI downloads chat.
- **The jitter fallback** will differ from the CLI's output (§4), so the
  comparison harness needs a VOD on each dispersion path.
- ~~**ImageIO** decoding animated WebP from 7TV.~~ **Verified 2026-09-17:**
  ImageIO read all 242 cached 7TV `.webp` emotes — 15,356 frames, up to 390 in
  one emote — with zero failures, decoding and drawing them in 3.95s. Note that
  `CGImageSourceCreateImageAtIndex` alone is lazy and returned in 0.6s; the
  honest number comes from drawing each frame into a context.

  Our own FFmpeg build, by contrast, decodes **zero** frames from these files.
  So the renderer must use ImageIO for emotes, and any harness step that tries
  to inspect emote files with `build/ffmpeg` will silently measure nothing.

### 9.1 Upstream candidates found while measuring this

Both are downstream-facing defects of the kind `twitch-downloader-cli-upstream-prs`
already tracks, and both are independent of whether this experiment proceeds.

1. **Username colours are not stable between runs.** `ChatRenderer.cs:1739`
   indexes `DefaultUsernameColors` by `display_name.GetHashCode()`, which .NET
   randomises per process. The intent is plainly a stable colour per viewer;
   the effect is a different colour in every render, for 14% of messages in the
   reference window. A non-randomised hash over the name fixes it. Strong
   candidate: small, obviously a bug, and demonstrable with two renders of one
   file.
2. **`chatdownload -E` decodes every animated emote frame it embeds.**
   `TwitchEmote`'s constructor runs `ExtractFrames` (`TwitchEmote.cs:34`),
   decoding all frames into `SKBitmap`s. The embed loop
   (`ChatDownloader.cs:561`) reads only `Id`, `ImageScale`, `ImageData`,
   `Name`, `Width`, `Height`, `IsZeroWidth` — and `Width`/`Height` come from
   `EmoteBitmaps[0].Info` when `Codec.Info` already carries them without
   decoding a pixel. Measured: **57s** to "load" 240 already-cached 7TV emotes
   with zero downloads.

   For scale, the same 242 cached files decoded **and drawn** through ImageIO
   — 15,356 frames, up to 390 per emote, 124 Mpx — take **3.95s** on this
   machine (`decode2.swift`, §12). So the work is both unnecessary here and
   roughly 14x slower than the platform decoder; the 57s also covers cache
   reads and object construction, which were not measured apart.

   Weaker than 1 as a PR: the constructor is shared with the render path, where
   the frames *are* needed, so the fix is a lazier `TwitchEmote`, and it needs
   a render-path measurement to show nothing regresses.

## 10. Open questions

1. **What is the time budget, and what happens when it runs out?** The whole
   design depends on actually stopping.
2. **Bundle Inter, or switch the default to the system font?**
3. **Is Phase 0's `-E` change worth shipping on its own**, regardless of
   whether the renderer is built? §3.1 says it trades 130 MB of intermediate
   file on a 7.5-hour VOD for a render that is 4.5x faster and offline. The
   answer probably depends on 4.
4. **Should the CLI's emote cache be shared across jobs?** Each step gets a
   fresh temp directory today, so every job re-fetches every emote —
   `-E` or not. Sharing one cache roughly halves the embed cost and would make
   3 clearly worth it, but it is a new piece of long-lived state in the
   workspace, with its own invalidation question (`cli-dependency.md` §3's
   "Fix emote cache to use Id instead of Name" is upstream getting this
   wrong).
5. **Does Phase 3 need a user-visible choice** during its one release, or is a
   hidden default enough?

## 11. Not in scope

- Replacing `chatdownload`, `info`, `clipdownload` or `videodownload`.
- Any change to how the chat column looks beyond §5's accepted differences.
- An in-app chat preview. `frame(at:)` makes it possible; this document does
  not build it.
- Removing the .NET runtime from the bundle.

## 12. Reproducing the measurements

All of §3.1, §8.1 and §9.1 came from the bundled helper and `build/ffmpeg`, on
this machine, 2026-09-17. Nothing here needs the app.

```bash
# embedded vs plain, and the download cost (§3.1). --temp-path is the emote
# cache: reuse one to measure warm, use a fresh one to measure what a job pays.
build/helper/TwitchDownloaderCLI chatdownload --banner=false --collision Overwrite \
  --id 2856361990 -b 9000 -e 9180 -o chat.json --temp-path tmp        # plain
build/helper/TwitchDownloaderCLI chatdownload --banner=false --collision Overwrite \
  --id 2856361990 -b 9000 -e 9180 -o chat-E.json --temp-path tmp -E   # embedded
```

Pin the username colours before comparing anything, or 98% of frames differ for
no reason (§8.1):

```python
import json
d = json.load(open("chat-E.json"))
for c in d["comments"]:
    c["message"]["user_color"] = c["message"].get("user_color") or "#FF69B4"
json.dump(d, open("fixed.json", "w"))
```

Render losslessly — `ffv1`, not `h264_videotoolbox` — so a frame difference is
the renderer's and not the encoder's, and compare by decoded-frame hash:

```bash
build/helper/TwitchDownloaderCLI chatrender --banner=false --collision Overwrite \
  -i fixed.json -o a.mkv --temp-path tA --ffmpeg-path build/ffmpeg/ffmpeg \
  -w 342 -h 1026 --framerate 30 --font-size 15 -f "Inter Embedded" \
  --background-color "#111111" --alt-background-color "#191919" \
  --message-color "#ffffff" --outline-size 4 --dispersion --offline \
  '--output-args=-c:v ffv1 -pix_fmt bgra "{save_path}"'

build/ffmpeg/ffmpeg -v error -i a.mkv -f framemd5 - | grep -v '^#' | awk -F, '{print $6}' > a.md5
paste -d' ' a.md5 b.md5 | awk '$1!=$2' | wc -l    # differing frames
```

`--offline` needs an empty `--temp-path` to prove anything: the CLI will
happily read a provider list left behind by an earlier run.

To see *what* differs rather than how much, stack the two frames and their
difference (our FFmpeg has no PNG encoder — write PPM and convert):

```bash
build/ffmpeg/ffmpeg -v error -y -i a.mkv -i b.mkv -filter_complex \
  "[0:v]select=eq(n\,3000),format=rgb24,split[a][a2];[1:v]select=eq(n\,3000),format=rgb24,split[b][b2];\
   [a][b]blend=all_mode=difference,lutrgb=r=val*8:g=val*8:b=val*8[d];[a2][b2][d]hstack=inputs=3" \
  -frames:v 1 -c:v ppm f.ppm && sips -s format png f.ppm --out f.png
```

The ImageIO figures in §9.1 come from a throwaway `swift decode2.swift <dir>`
over `tmp/TwitchDownloader/stv`: `CGImageSourceCreateImageAtIndex` for every
index, each frame drawn into a `CGContext` to force a real decode. Skipping the
draw measures nothing, because `CGImage` creation is lazy.
