# Compositing the VOD and chat into one video — design

**Status:** approved 2026-08-25. All four phases (the engine, scheduler,
geometry, parser, and argv; then narrowing the intake to the two-choice UI in
§3, deleting the standalone render UI, and the font-size calibration)
implemented on branch `compositing`.

Prerequisites: `docs/design/task-queue.md` (the engine and its templates),
`docs/design/chat-and-render.md` (the intake this narrows), and
`docs/ffmpeg.md` (the licence constraints, which still bind).

This design also **settles the open question in `docs/architecture.md` §7,
"Narrowing the intake."** That section recorded a leaning and explicitly
declined to decide. It is decided here: the intake becomes two choices, and
the standalone chat render is removed.

---

## 1. What this delivers

Paste a VOD or clip link and choose one of two things: **the video**, or **the
video with its chat rendered alongside it**, composited into a single file.

Neither upstream's CLI nor its WPF app does this. It is the first feature where
Oxbow is more opinionated than the tool it wraps rather than less, and the two
halves of that are inseparable: the composite is what makes a standalone chat
render pointless, so the same change that adds one removes the other.

## 2. Verified before designing

The filter graph was driven end to end against the real bundled LGPL FFmpeg
(8.1.2, `build/ffmpeg/ffmpeg`) on 2026-08-25, with synthetic inputs chosen to
exercise the failure modes: a 1920x1080@60 "video" with AAC audio and a
360x1080@**30** "chat" that is deliberately **shorter** than the video.

| Question | Answer |
|---|---|
| Does a chat render that ends early truncate the video? | **No.** 3s chat under a 5s video produced `frame=300` (5s x 60) and a 5.00s output. `hstack`'s default `eof_action=repeat` holds the last chat frame. |
| Does the 30-into-60 rate mismatch work? | **Yes**, once normalised with `fps=` on the chat input. Output is a clean CFR 60. |
| Output geometry and audio | **2280x1080, 60 fps, AAC stream-copied**, decodes clean under `-f null -`. |
| Is there a usable ETA? | **Yes.** `-progress pipe:1` reports `speed=` in every block. |
| What happens on a height mismatch? | **Exit 234 in 0 seconds**, message `Input 1 height 900 does not match input 0 height 1080`, and a **0-byte** output file. |

Two findings that contradict what the design assumed going in, recorded so they
are not re-assumed:

- **`h264_videotoolbox` does NOT reject odd widths.** It accepts them and
  **silently crops**. 1920 + 351 exited 0, decoded clean, and produced
  **2270x1080 — not 2271** — with no warning at `-loglevel error`. The
  even-width rule in section 4 exists because of this silent crop, not because
  the encoder complains.
- **`out_time_ms` is actually microseconds.** Both `out_time_us` and
  `out_time_ms` read `4983333` for 4.983 seconds. The parser must read
  `out_time_us`. Do not "fix" this to `out_time_ms`; it is wrong by 1000x.

## 3. Intake: two choices

The three independent toggles from `chat-and-render.md` §2 — Video, Chat,
Render chat — collapse to a single two-case choice:

1. **Video + chat** — listed first, and the default.
2. **Video**

Applied symmetrically to clips: clip + chat, or clip. A clip composite is
seconds of work, so there is no reason to withhold it.

**Chat is the default** because it is the reason to reach for Oxbow rather than
any of the video-only downloaders that already exist, and the cost of the wrong
default is asymmetric: a user who wanted only the video clicks one radio button,
while a user who did not know the composite existed never discovers it. The
composite is also the only output that cannot be added after the fact — a
`.mp4` on disk is not a job the queue can extend.

One consequence, and it is the reason `IntakeModel.chatProblem` has a second
case: when the metadata fetch fails there is no rendition to size the chat
column against and no duration to time the encode, so the default output is
precisely the one that cannot be built. Add would grey out on a freshly opened
sheet with nothing on screen saying why. The refusal therefore carries its
sentence and names *Video*, exactly as the expired-broadcast case does.

There is no standalone chat render, no standalone chat file, and no chat format
picker. The argument is the one already recorded in `architecture.md` §7: a
rendered chat video in isolation has little use, and a Mac app earns its keep by
having a view about what people actually want where the CLI's job is to expose
every combination. Anyone who wants a bare chat render can run the CLI.

**`JobTemplate` keeps its struct-of-optionals shape.** `chat-and-render.md` §5
rewrote it from a five-case enum into a composition one day before this design,
because three toggles composed into eight combinations. Two choices would fit an
enum again — but reverting is churn, the struct still expresses media x chat
honestly, and clips already double the shapes. Intake simply stops constructing
the other combinations.

## 4. Geometry, derived

Everything geometric is known at intake, before a byte is downloaded, from
`VideoInfo` alone. Nothing is probed: the bundled FFmpeg is built with
`--disable-ffprobe`, and nothing needs it.

| Constant | Rule | 1080p | 720p | 480p |
|---|---|---|---|---|
| Chat width | video width x 3/16, forced even | 360 | 240 | 160 |
| Chat height | = video height, after metadata is rounded down to even — see below | 1080 | 720 | 480 |
| Output width | video width + chat width | 2280 | 1520 | 1012 |
| Chat framerate | the video's, halved when it is 60 | 30 | 30 | 30 |
| Font size | user's Small/Medium/Large, scaled to chat width — see below | 13 / 16 / 20 | 9 / 11 / 13 | 6 / 7 / 9 |
| Render bitrate | flat 12 Mbps at every quality — see below | 12M | 12M | 12M |
| Composite bitrate | derived from the source's own bitrate — see below | — | — | — |

**3/16** is chosen because it lands on exact even integers at most standard
Twitch widths. It does not at all of them, so the chat width is still forced
even at the point of derivation regardless — h264_videotoolbox does NOT reject
an odd width, it accepts it and silently crops a column (§2: 1920+351 produced
2270x1080, exit 0, no warning).

### Metadata dimensions are rounded down to even before anything is derived

An earlier version of this section chased odd *video* widths and heights with
a parity rule and an outright refusal, on the premise that Twitch renditions
can genuinely carry odd dimensions. **That premise was wrong.** A real
download of the `480p30-Portrait` rendition — whose clip-API metadata claims
`480x853` — decodes as:

```
Video: h264 (Main), yuvj420p, 480x852
```

h264 4:2:0 (`yuv420p`/`yuvj420p`, what every Twitch rendition uses) cannot
carry an odd coded width or height — the chroma planes are half-resolution on
both axes, so an odd luma dimension has no valid chroma sample to pair with.
**An odd dimension in Twitch's metadata is therefore always a rounding
artifact, never a real frame.** The clip API derives it arithmetically
(480 x 16/9 = 853.3, rounded) rather than reporting the coded size — which is
also why the same nominal 480p rendition reads `852x480` from a VOD's m3u8 but
`853x480` from the clip API: two different derivations of the same real frame.

This is why deriving the chat render's height from the metadata's `853`
produced the failure this design exists to avoid: the video itself decodes at
`852`, `hstack` requires its two inputs to agree exactly on height, and a
1-pixel mismatch is exit 234 and a 0-byte output (§2), immediately.

**The fix: `CompositeGeometry.init?` rounds both metadata dimensions down to
the nearest even value, as its very first step**, before anything —
`chatWidth`, `videoHeight`, the render's dimensions — is derived from them.
Rounding down (rather than up, or refusing) is what makes the render agree
with what the video actually decodes to, since the decoder itself always
truncates. Everything past that first step (the 3/16 chat-width rule, the
even-forcing, the minimum-width clamp) is unchanged and operates on the
already-corrected, always-even `videoWidth`/`videoHeight` — so an odd chat
width can still arise from an even video width (852 x 3/16 = 159) and is still
forced even the same way it always was; there is no longer a parity rule to
apply, because the video dimension it would have matched against no longer
exists.

Worked examples (metadata -> the video dimensions actually used -> chat
width -> output), all even on both axes:

| Metadata | Effective video | Chat width | Output |
|---|---|---|---|
| 1920x1080 | 1920x1080 | 360 | 2280x1080 |
| 1280x720 | 1280x720 | 240 | 1520x720 |
| 853x480 | 852x480 | 160 | 1012x480 |
| 480x853 (portrait) | 480x852 | 160 (clamped) | 640x852 |
| 640x360 | 640x360 | 160 (clamped) | 800x360 |
| 1146x646 | 1146x646 | 214 | 1360x646 |

Because the round-down happens before any other rule, a rendition Twitch
reports with an odd dimension is no longer refused (the earlier, wrong fix
would have rejected `480p30-Portrait` outright) and no longer needs a
width-only parity correction (the earlier, also-wrong fix): it simply
composites at the one-pixel-smaller size the stream actually is.

**Framerate comes from the quality *name*** (`1080p60` -> 60), never from the
m3u8's `FRAME-RATE` attribute, which reports a measured average (57.034 on a 60
fps VOD) and would reintroduce exactly the drift this avoids. This is the note
already recorded in `architecture.md` §7, now load-bearing.

**Chat framerate should be the video's rate divided by a small integer, not
necessarily equal to it.** Mismatch never breaks synchronisation — `hstack`
holds the last chat frame — so this is a cost and judder question, not a
correctness one. Rendering chat at 60 roughly doubles the chat render step for
motion nobody perceives in a slowly scrolling column; a non-harmonic ratio (30
into 24, or 30 into 50) makes chat frames land unevenly against video frames and
scroll visibly unevenly. Halving 60 and matching 30 satisfies both.

### The empty-quality hole, and its fix

`VideoRequest.quality == ""` means "best available" and is the **default**
selection (`chat-and-render.md` §6). That is the one path where the resolution
is unknown at intake — which is fatal here, because the chat render's height
must equal the video's.

**For composite jobs, intake resolves an empty quality to `qualities.first` and
passes it explicitly as `-q`.** The list is already in hand from the `info`
call, so this costs one line. Non-composite jobs keep today's behaviour
untouched.

`hstack` remains the backstop for the residual case where Twitch delivers
something other than what its own m3u8 advertised. Section 2 shows that failure
is loud, immediate, and costs zero encoding.

### The intermediate render's bitrate

`RenderRequest.bitrateMbps` defaults to 3. That was correct when the render was
a deliverable. It is now an intermediate that is immediately decoded and
re-encoded, so at 3 Mbps the composite carries **two generations of lossy H.264
over text on flat backgrounds** — the exact content where H.264 shows mosquito
noise worst — and the second pass then spends bits encoding the first pass's
artefacts.

The fix is free: encode the intermediate at **12 Mbps**. At fixed resolution and
framerate, VideoToolbox's encode speed is essentially independent of bitrate, so
this costs only transient disk in a workspace that is deleted anyway.

### The composite's own bitrate: corrected, not copied

The first cut seeded the composite's bitrate straight from the source's own
rate — `max(StreamQuality.bitsPerSecond / 1_000_000, 6)`. That under-budgets
it two ways at once: the composite frame is wider than the source (video plus
chat column, roughly 19% more pixels at 1080p — 2280 vs 1920), so the same
bitrate is spread over more pixels than it was measured against; and it is
re-encoding material that is already lossy, which costs bits the first encode
didn't need to spend. On a visually noisy source the game footage soaks up the
budget first and the chat column — sharp, high-contrast text on a flat
background, H.264's worst case — visibly degrades.

**Measured on a real clip** (LeighXP, FF7 Rebirth, 1080p60 @ 6128 kbps), chat
region compared against the pristine chat render:

| Composite bitrate | PSNR | SSIM |
|---|---|---|
| 6 Mbps (the source's own rate — the old seed) | 25.5 dB | 0.916 |
| 11 Mbps (this formula's output) | 29.5 dB | 0.952 |
| 16 Mbps | 31.9 dB | 0.963 |

**Also measured: bitrate is free in wall-clock time.** 6.0s to encode at 6 Mbps
vs 6.1s at 16 Mbps, same clip. `h264_videotoolbox`'s encode speed does not
depend on the bitrate target, so — as with the intermediate render's bitrate
above — there is no cost tradeoff to erring generous. Only file size grows.

**The fix (SUPERSEDED 2026-08-29 — see below):**

```
compositeBitrateMbps
  = round( sourceBitsPerSecond x (outputWidth / videoWidth) x 1.5 / 1_000_000 )
    floored at 6
```

> **This formula no longer exists.** The `sourceBitsPerSecond` term was removed
> in full: measured across sixteen samples it is *anti-correlated* with need —
> both quiet VODs advertise more bandwidth than both busy ones — so it gave
> least to the streams that needed most. `BANDWIDTH` is a peak describing the
> rendition's ceiling, not the difficulty of the footage.
>
> The rate now derives from the composite frame's own pixel rate at 0.12 bits
> per pixel, floored at 10. The measurements below remain valid for what they
> measured — that the *old* seed starved the chat column, and that bitrate is
> free in wall-clock time — but the diagnosis of *which* bitrate and *why* is
> superseded by [`composite-quality.md`](composite-quality.md), which also
> shows the requirement spans 7.5x across real content and that no constant
> can serve it.
>
> The 6 Mbps floor is likewise gone: it measured 18.1 dB against a pristine
> chat render, which is visibly mush.

*(Historical, describing the superseded formula.)* `outputWidth / videoWidth`
corrected for the extra pixels the composite frame carries over the source and
the flat `1.5` was re-encode headroom, both named constants. The `6` Mbps floor
was the same floor the old flat seed used.

The reasoning that survives is the *observation* — that the chat column is
sharp, high-contrast text on a flat background, H.264's worst case, and that a
visually noisy source starves it. What did not survive is deriving the answer
from the source's own bitrate; see the note above.

Worked examples, all at 1080p (`outputWidth / videoWidth` = 2280/1920 =
1.1875):

| Source bitrate | Composite bitrate |
|---|---|
| 6,128,000 bps | 11 Mbps |
| 9,685,000 bps | 17 Mbps |
| 6,184,000 bps | 11 Mbps |

### Chat text size: a survivor, scaled rather than fixed

Font size is the one control the deleted render-options form (§8) left
behind. Intake offers **Small / Medium / Large**, defaulting to Medium, shown
only when *Video + chat* is selected. The reason it stays a choice rather than
becoming one more baked-in constant like everything else in this section: the
chat column is not a fixed width, it is `videoWidth x 3/16` — 360px at 1080p,
240px at 720p, 160px at 480p. A point size that reads well in a 360px column
looks cramped in a 160px one and undersized in reverse, and separately, what
reads well on a laptop window is not what reads well on a TV across the room.
A single fixed default cannot serve both axes at once; a proportional preset
can.

**What *is* fixed by inspection, and what is derived from it, are different
things.** The anchors — 13/16/20 for Small/Medium/Large — were chosen the way
the old flat default was: rendering real chat at 360x1080 (1080p's column)
and looking at the result, at roughly 35, 28, and 19 messages visible. But
those anchors are not the whole rule. Divided back by the 360px column that
produced them, they give a ratio the app applies at *every* resolution, so the
same choice looks the same relative size everywhere rather than needing its
own inspected anchor per quality:

```
base   = chatWidth / 22.5   # Medium
Small  = base x 0.8
Medium = base x 1.0
Large  = base x 1.25
```

Rounded to the nearest whole number, never below 1. `CompositeGeometry.fontSize(for:)`
implements this; the divisor and the three multipliers are named constants
with a comment recording that they came from inspection, not derivation, so a
size that reads wrong later is a one-line fix rather than a re-derivation.

| | 1080p (360) | 720p (240) | 480p (160) |
|---|---|---|---|
| Small | 13 | 9 | 6 |
| Medium | 16 | 11 | 7 |
| Large | 20 | 13 | 9 |

## 5. The composite step

A new `StepKind.composite(CompositeRequest)`, resource class `.compute`, which
spawns **`ffmpeg`** rather than the helper. It consumes two artifacts and
produces one.

```swift
public struct CompositeRequest: Codable, Sendable, Equatable {
  /// The video's framerate. The chat is normalised up to it.
  public var framerate: Int
  public var bitrateMbps: Int
  /// Needed only so the progress parser can turn `out_time_us` into a
  /// fraction. Known from `VideoInfo` at intake.
  public var duration: Duration
  public var destination: URL
}
```

It carries no geometry, because `hstack` derives all of it from the inputs.

The argv, verified in section 2 and (for the two changes resuming required —
the sidecar output and the fragmented `-movflags`) in
docs/design/resume.md §2 and §4:

```
ffmpeg -nostdin -y -hide_banner
  -i {video} -i {render}
  -map "0:a:0?" -c:a copy {resume-area}/audio.m4a
  -filter_complex "[0:v]fps={framerate}:start_time=0[v];
                   [1:v]setpts=PTS-STARTPTS,fps={framerate}[c];
                   [v][c]hstack=inputs=2[out]"
  -map "[out]" -an
  -c:v h264_videotoolbox -b:v {bitrate}M -pix_fmt yuv420p
  -movflags +frag_keyframe+empty_moov+default_base_moof
  -progress pipe:1 -nostats -loglevel error
  {piece}
```

Every element is load-bearing:

- **`fps=…:start_time=0` on the video, never `setpts=PTS-STARTPTS`.** It pads
  the head rather than shifting the track, and that distinction is the whole
  point. A trimmed download legitimately begins its video stream *after* its
  audio: upstream trims with an input `-ss` and `-c copy`
  (`VideoDownloader.RunFfmpegVideoCopy`), a stream copy can only start video on
  a keyframe, so the file honestly records `video start_time = 0.866, audio
  start_time = 0.000` and every player honours the gap.

  The audio never enters this filter graph — it is `-c:a copy`-ed to the
  sidecar above and remuxed untouched at `.assemble` — so zeroing the video's
  PTS rebased the two halves of one source by different amounts. Measured on a
  real 20-minute delivery trimmed to 50:00–70:00: the video ran **0.866s ahead
  of its audio**, constant at both ends of the file (24-frame lag at 0–65s and
  again at 1140–1200s, against fresh reference downloads of the same ranges;
  correlation minimum 12.1 versus 41 and 43 one sixth of a second either side).
  Replaying this argv against a clean download reproduced the identical lag,
  which is what pinned it here rather than on the CLI.

  It is present without a start trim too, at 0.058s — two frames, which is why
  it went unnoticed until someone trimmed to a point that was not a part
  boundary and it grew to a keyframe interval.

  It is deliberately not a bare *removal* of the reset either: dropping it
  outright made `h264_videotoolbox` abort mid-encode on a source starting at
  0.666s (`composite-quality.md` §9). The video stays zero-based and CFR; only
  the padding changes.
- **`setpts` precedes `fps` on the chat**, which starts at zero, so the rate
  conversion runs on a zero-based timeline.
- **`hstack`, not `pad` + `overlay`.** The tolerant alternative accepts a
  mismatched chat render and produces a subtly wrong 22 GB file with a black
  band under the chat. `hstack`'s strictness is the feature: a one-second
  failure instead of a seventy-five-minute one.
- **No `shortest=1`.** Chat renders end at the last message. A stream that goes
  quiet for its final twenty minutes would have had its *video* truncated. This
  is a real defect in the Ruby prototype this design replaces.

  **A resumed composite has to honour the same fact a second time**, and
  `eof_action=repeat` is not enough on its own there: seeking a render past its
  own end yields no frames at all, and `hstack` cannot repeat a frame that
  never arrived. The chat's seek is clamped for that case — see
  `docs/design/resume.md` §12.
- **No `scale` on either input.** The chat is rendered at the right size by the
  render step; the video is already native. The prototype's `scale=w:h` to the
  source's own dimensions ran swscale over every frame for nothing.
- **`-map "0:a:0?" -c:a copy {audio.m4a}` is a second, complete output, not
  something attached to the composite's own file.** FFmpeg accepts several
  outputs in one invocation, so copying the source's audio out beside the
  piece costs nothing measurable — and it is what lets the re-fetched video be
  deleted before `.assemble` runs rather than surviving to deliver its audio.
  Written only on a first attempt (`resumeFrom == nil`); a resumed attempt
  holds only the tail, so re-extracting here would truncate the sidecar to
  it. The `?` still makes the map optional so a silent VOD does not hard
  fail. docs/design/resume.md §4.
- **`-an` on the piece itself.** The composite's own output carries no audio
  at all — it is mapped once, into the sidecar above. A piece carrying its
  own audio track would double it up for nothing: `.assemble` never reads a
  piece's audio, it maps `1:a:0?` from the sidecar. docs/design/resume.md §2.
- **`-movflags +frag_keyframe+empty_moov+default_base_moof`.** The piece is a
  fragmented MP4, so a crash mid-encode leaves a structurally valid prefix
  behind rather than an unreadable file — the entire precondition for
  resuming at all. docs/design/fragmented-output.md §3. (The sidecar is not
  fragmented, which is a real, currently-unfixed gap of its own —
  docs/design/resume.md §2, "Verified end to end".)
- **No `-movflags +faststart`.** It rewrites the entire file to relocate the
  moov atom, which on a 22 GB output is minutes of pure disk churn buying HTTP
  progressive streaming that a local file does not need.
- **`-nostdin`.** FFmpeg reads stdin by default and would otherwise contend
  with the spawner's pipe.

## 6. The model change: two parents

A composite consumes the video download **and** the chat render.
`Step.dependsOn` is a single `StepID?`, documented as "at most one parent, so
this is a forest and never needs a topological sort." That stops being true.

`dependsOn` becomes `[StepID]` and `StepContext.inputArtifact` becomes
`inputArtifacts: [URL]`. The touch points are all pure and already unit-tested:

- `Scheduler.admissible` requires **all** parents `.done`.
- `blockDependents` still terminates — `makeJob` builds an acyclic graph.
- **`unblockDependents` grows a genuinely new rule.** Retrying one failed parent
  must not requeue a step whose *other* parent is still failed. This is a latent
  bug if missed and has no equivalent in the single-parent model.
- `Step` is `Codable` and `QueueStore` persists it. A custom `init(from:)` that
  decodes either a scalar or an array is about ten lines and removes the need
  for a migration.

**The rejected alternative** was to chain the steps — video -> chat -> render ->
composite — which needs no model change at all. It was rejected for failure
isolation and retry granularity: chaining the video behind the chat/render pair
means a chat-download hiccup fails the whole chain, and retrying either half
means re-running the whole chain in front of it — there is no "retry render
without re-fetching the video" if the video's own success is what the chain's
position depends on. The two-parent DAG keeps the video and the chat/render
pair independently retryable, which the single-parent model cannot express.
It also keeps `makeJob`'s standing invariant that "a failed video download must
not block the render, and vice versa."

**It is not, on its own, a wall-clock win.** `StepKind.resource` puts
`downloadVideo`, `downloadClip`, and `downloadChat` all in `.network`, and
`Scheduler.admissible` admits at most one running step per resource class,
globally. A DAG with the media step appended *first* (chat and render appended
after) still serialises: the video takes the network slot, the chat waits
behind it, the render waits on the chat, and the composite waits on both — the
exact chained timeline above, just expressed as a DAG instead of a chain. The
parallelism `ResourceClass` is meant to buy therefore depends on step
*ordering*, not on the dependency shape: `JobTemplate.makeJob` appends the chat
and render steps before the media step, so the short chat download claims the
network slot first, and once it finishes, the render (`.compute`) and the video
download (`.network`) become admissible in the same `Scheduler.admissible`
call. The realised timeline is `chat + max(video, render) + composite`, not the
serial `video + chat + render + composite` a naive append order would produce.

**Wall-clock time is still the binding constraint on this feature** — a
six-hour stream is already ~75 minutes of compositing even with the corrected
timeline above — it just is not, itself, an argument for the DAG's shape. Any
further design choice that trades time for anything else loses by default.

### Destinations become optional

Composite delivers **one file**. `VideoRequest.destination`,
`ClipRequest.destination`, and `RenderRequest.destination` all become `URL?`,
matching `ChatRequest`; on a composite job every one of them is `nil`, so the
inputs stay in the workspace and are discarded with it. Clips are included
because §3 gives them the same two choices as VODs. `QueueEngine.move`'s comment that `ChatRequest.destination` is "the only
optional one of the four" is corrected.

The composite takes the plain `{base}.mp4` filename. The user asked for the
video and gets one file.

## 7. Execution

**Per-step executable.** `QueueEngine.launch` hardcodes
`configuration.helperExecutable`. It becomes a function of the step kind: the
helper for the four CLI verbs, `configuration.ffmpegPath` for `.composite`.

**The parser dialect.** `HelperProcess.run` hardcodes `StatusLineParser()` in
its stdout pump, and FFmpeg's `-progress` output is a different protocol
entirely. `Launch` gains `dialect: OutputDialect` — an enum of `.helper` and
`.ffmpeg` — and `run` selects the parser from it. An enum rather than an
injected closure keeps `Launch` `Sendable` without a capture, keeps the choice
table-driven in tests, and preserves `ParsedLine`'s invariant that only a parser
ever touches raw text.

**`FFmpegProgressParser`**, a sibling to `StatusLineParser`, and pure the same
way: no clock, no I/O. `-progress pipe:1` emits repeating blocks of twelve
`key=value` lines terminated by `progress=continue`, with a final
`progress=end`. Observed keys, in order:

```
frame  fps  stream_0_0_q  bitrate  total_size
out_time_us  out_time_ms  out_time  dup_frames  drop_frames  speed  progress
```

Mapped into the existing `StepProgress`:

- `fraction` = `out_time_us` / `duration`.
- `remaining` = (`duration` - `out_time`) / `speed`. **Guard `speed=0`** — early
  blocks report degenerate rates, and the first observed block had `fps=0.00`.
- `elapsed` stays `nil`. Deriving it means reading a clock, which this parser
  does not get to do; `StepProgress`'s fields are optional for exactly this.

**Failure interpretation needs almost nothing.** `FailureInterpreter` already
treats any non-zero exit as failure *regardless of whether an artifact exists*,
so a 20 GB half-written composite from an FFmpeg that died at 90% is correctly
rejected rather than moved to the user's folder. Two small changes:

- Its fallback sentence reads "The download tool failed without reporting a
  reason," which is wrong for a step that is not a download.
- **Strip FFmpeg's `[component @ 0xaddr] ` prefix.** The existing "first line
  that is not a stack frame" fallback already surfaces the right line, but with
  `[Parsed_hstack_3 @ 0x87101cd80] ` glued to the front.

Its `---> ` inner-exception heuristic is .NET-shaped and simply will not match.
That is fine.

**Cancellation needs nothing.** `HelperProcess.cancel` already sends SIGTERM to
the process group before SIGKILL, and its own doc comment explains that SIGTERM
is "purely for FFmpeg's benefit — it closes its output file on receipt." Written
for the CLI's grandchild FFmpeg; correct unchanged for a direct one.

## 8. What gets deleted

| File | Lines | Why |
|---|---|---|
| `Oxbow/Intake/RenderOptionsView.swift` | 192 | Colours, font, badges, emotes, and bitrate all become fixed defaults |
| `Oxbow/Intake/HexColor.swift` | 60 | Its only consumer was that view's colour wells |
| `OxbowTests/HexColorTests.swift` | 103 | With it |

Not everything the deleted form controlled becomes a fixed default, though:
**chat text size survives**, as the Small / Medium / Large picker in §4. Every
other control there was either derivable (height, framerate) or a decision the
app can simply make well (colours, badges, timestamps), but size is neither —
a fixed point size cannot serve both a laptop window and a TV across the room,
where the same column reads at very different physical sizes. So this is not
"the render UI, deleted entirely, appearance fixed everywhere": it is that
form's controls deleted down to the one dimension a fixed default cannot
answer for everyone.

From `IntakeModel`: `isDownloadingMedia`, `isDownloadingChat`, `isRenderingChat`,
`chatFormat`, `renderOptions`, `renderIsInvalid`, `renderProblems`,
`deliveredChatFormat`, and `hasSelectedOutput`, replaced by one two-case enum
plus `chatSize`.
`IntakeSheet`'s three toggles become a picker, alongside the new Small /
Medium / Large one. `IntakeModelTests` (882 lines) is pruned heavily.

**`OutputSuffix` loses `.chat` and `.render`**, dropping `longestBytes` from 12
to 4. This *loosens* `OutputNaming`'s truncation reserve — titles may now be
eight bytes longer — and `IntakeModelTests` asserts `longestBytes == 4`
explicitly.

**`ChatFormat` and `JobTemplate.renderInput` survive**, though intake no longer
exercises them. `JobTemplate` is public library surface, and a caller composing a
template directly still needs the guard that a render's chat input is JSON.
Deleting it saves nothing at runtime and removes a safety net that landed one
day earlier.

**`RenderRequest` also keeps every field the deleted form used to set**:
`isSharpened`, `hasOutline`, `hasTimestamps`, `hasAlternateBackgrounds`, the
colours, and `font`. This is deliberate, not leftover — `RenderRequest` is
`OxbowKit` library surface, not app UI, and `ArgumentBuilder` still needs
somewhere to read these from when a caller (or a future form) wants them.
Intake now always constructs one at its `init` defaults, so in practice every
composite and render this app builds runs with the same fixed values; nothing
prunes the fields themselves, only the UI that used to vary them.

## 9. Testing

| Unit | Covered by |
|---|---|
| `FFmpegProgressParser` | the twelve-key block; blocks split mid-chunk; `progress=end`; `speed` -> `remaining`; `speed=0` guarded; `out_time_us=N/A`; missing keys |
| `ArgumentBuilder` `.composite` | the exact filter graph, `-nostdin`, the sidecar's `-map "0:a:0?" -c:a copy`, the piece's own `-an`, the fragmented `-movflags`, absence of `+faststart`; the two GPL rules still hold |
| `Scheduler.admissible` | a two-parent step is not admitted until both parents are `.done` |
| `Scheduler.retry` | retrying one failed parent does not requeue a step whose other parent is still failed |
| `Scheduler.blockDependents` | failing either parent blocks the composite |
| `Step` decoding | a persisted scalar `dependsOn` decodes to a single-element array |
| `JobTemplate.makeJob` | both intake shapes, x2 for clips; the composite's two dependency edges |
| Geometry derivation | width/height/framerate per standard quality name; rounding an odd metadata width or height down to even before deriving anything else (the 853-wide and 853-tall cases, including the minimum-clamp interaction); empty quality resolving to `qualities.first` |
| Composite bitrate | the pixel-ratio x headroom formula against the measured clip's values; the 6 Mbps floor |
| `OutputNaming` | `longestBytes` 12 -> 4 and its effect on truncation |
| `QueueEngine` | `.composite` spawns `ffmpegPath`, not `helperExecutable` |
| `FailureInterpreter` | the real height-mismatch stderr from section 2, with the `[component @ 0x…]` prefix stripped |

Plus one end-to-end run against a real VOD before this is called done — the same
bar `chat-and-render.md` §2 set for itself.

### Measured on that run

Run against a real 16:31 VOD at 1080p60. Extrapolated to a six-hour stream:

| Step | Time |
|---|---|
| Download | ~9 min |
| Chat render | ~14 min |
| Composite | ~74 min (4.86x realtime measured, against the 4.79x §6 predicted) |

Two things the numbers above don't capture, worth recording because neither is
in the cost analysis elsewhere in this document:

- **Peak disk for a six-hour job is 55-120 GB, not ~22 GB.** The composite step
  reads the downloaded video and the intermediate chat render while writing the
  output, so all three exist on disk simultaneously. Recomputed after §7's
  bitrate correction, which raised the output and therefore the peak:

  | six-hour VOD | video | render | output | peak |
  |---|---|---|---|---|
  | 6.2 Mbps source | 16.3 GB | 10.2 GB | 29.0 GB | **55.5 GB** |
  | 9.7 Mbps source | 25.5 GB | 10.2 GB | 44.8 GB | **80.5 GB** |
  | at the bitrate cap | 52.7 GB | 10.2 GB | 58.0 GB | **120.9 GB** |

  An earlier draft of this section said ~44 GB. That was measured before the
  bitrate correction and is wrong; fixing the artifacts made the feature
  hungrier, not leaner, and the honest number is the one above.

  **Nothing checks this.** Someone who starts a six-hour job with 45 GB free
  fails roughly seventy minutes into the encode, with tens of gigabytes of
  unusable intermediates left in the workspace and a full disk. See §10.
- **Streamers who already burn a chat overlay into their broadcast get chat
  twice.** Observed in the test VOD: the streamer's own overlay is baked into
  the video, and our column repeats the same messages beside it. Not a defect,
  and not something we can fix — but a real limit on who this feature serves,
  worth stating so it is a known trade-off rather than a surprise.

## 10. Known and unbuilt

**The two speed items in this section were measured on 2026-08-26 and neither
survived. See `docs/composite-performance.md`** for the full spike: the composite
is bound
by `h264_videotoolbox`'s throughput at ~800 Mpx/s of output pixels, a single
FFmpeg process already extracts 94% of that, and everything else in the step runs
in the encoder's shadow. Read that document before proposing anything here — it
carries a formula (§5) that predicts any job's composite time in one line, and
six approaches that are now closed on evidence rather than instinct.

### A disk-space preflight

The most valuable unbuilt thing, and the one with a live failure mode: nothing
predicts the peak above before committing to a job.

**Trigger on predicted bytes, not on duration.** Duration is a poor proxy — a
thirty-minute 1080p60 clip at a high source bitrate needs more than a
three-hour 480p VOD. Everything needed is known at intake: `VideoInfo.duration`,
`StreamQuality.bitsPerSecond`, and `CompositeGeometry.compositeBitrateMbps`.
The intermediate render measures ~3.85 Mbps in practice (text on a flat
background compresses far below its 12 Mbps ceiling).

**Two volumes, not one.** `Workspace` lives in the app's cache directory on the
system volume; the destination is the user's chosen folder and may be an
external drive. `QueueEngine.move` uses `moveItem`, which across volumes is a
copy-then-delete — so the finished composite briefly exists on both. When they
are the same volume, everything stacks.

**Check twice.** At intake, where refusing is cheap and the user can still pick
720p and more than halve the requirement. And again immediately before the
composite step, because free space changes between queueing and running, and
failing before a seventy-minute encode is a different thing from failing during
it.

**Offer the remedy, not just the refusal.** "Needs ~80 GB, 45 GB free — 720p
would need ~28 GB" is actionable; "insufficient disk space" is not.

**Piping the chat render's raw frames into the composite.** The CLI already
pipes raw BGRA to its own FFmpeg, and we control `--output-args`, so
`{save_path}` could point at a FIFO carrying raw frames that the composite reads
as its second input, concurrently, eliminating an H.264 encode, a decode, and a
multi-GB intermediate.

**An earlier version of this bullet claimed ~1.7x faster wall clock and called
this the most valuable unbuilt thing here. Both were wrong.** Simulated exactly —
a producer process emitting raw frames into a pipe — the composite took **48.4s
against the baseline's 48.4s** in `yuv420p` and 48.5s in BGRA. The 12.6s of chat
decode it removes was never on the critical path; it runs inside the encoder's
shadow. The 1.7x was not arithmetically available either: §6's realised timeline
is `chat + max(video 9, render 14) + composite 74`, and the FIFO makes it
`chat + video 9 + composite 74` — **1.06x, about five minutes**, because the
render was already hidden behind the video download.

It remains worth something, just not speed: **10.2 GB off the 55–120 GB peak
above**, and a chat column encoded once from pristine frames rather than twice.
Weigh that against what it costs — the two processes become hard-coupled so a
stall in either blocks the other, FIFO cleanup on cancellation is nasty, and it
requires two `.compute` steps running simultaneously, which breaks `Scheduler`'s
one-per-class rule and trips the warning `ResourceClass` already carries about
blocking syscalls pinned on the cooperative pool. Five minutes and a quality
improvement do not buy that.

**`hevc_videotoolbox`** is present in our build and would roughly halve the
output at equal quality and essentially equal speed on Apple Silicon's media
engine — **measured, 49.9s against h264's 48.1s**, so "essentially equal" is
confirmed rather than assumed. It does not help the binding constraint and it
costs playback compatibility off-Apple, so it is recorded rather than shipped.

**An AVFoundation composition** was considered as an alternative to FFmpeg, on
the reasoning that `AVMutableVideoComposition` would keep frames as
`CVPixelBuffer`s on the GPU where `hstack` forces a decode -> CPU -> encode round
trip on every frame. **That reasoning was backwards, and is now closed by
measurement.** Benchmarked directly against pre-decoded frames in RAM,
`AVAssetWriter` encodes at ~612 Mpx/s to FFmpeg's ~755 — **19% slower** — and two
concurrent sessions reach only 804 Mpx/s, a 1.31x that a single FFmpeg process
already comes within 7% of. The CPU round trip AVFoundation would avoid is the
part that was already free. `QueueEngine`'s subprocess assumption stands as a
second reason, but it is no longer the load-bearing one.

**Two video tracks in one QuickTime movie, both stream-copied**, was the spike's
own idea and is the one worth knowing about: the mux takes **0.80s against 48.4**
and is losslessly better, but AVFoundation composites a translated `tkhd` matrix
only through an explicit `AVVideoComposition`, so QuickTime Player and Quick Look
show the 342-pixel chat column alone and VLC opens two windows. Dead until
`AVPlayerItem.presentationSize` on such a movie stops reporting the chat track's
size — a one-line test, worth re-running on a future macOS, because the payoff is
60x. See `docs/composite-performance.md` §4.5.

**Fragmenting the composite's output** is the non-destructive thing left, and it
is a concession rather than an optimisation — nothing makes the encode faster.
Writing the output as a fragmented MP4 costs 0.3s of wall clock and 123 bytes,
and makes the in-progress file readable to within ~0.4s of the live edge, so
time-to-first-watchable-frame falls from ~88 minutes to ~11 in one file under the
final name. More importantly it gives the step *valid partial state*, which is
what a resume would need. **Designed: `docs/design/fragmented-output.md`.**

An earlier version of this bullet proposed *segmenting* the composite into N
steps for the same purpose and claimed it would also lower the disk peak. Both
were wrong. Segments cannot be joined into a playable growing file — AVFoundation
will not cross the seam between two encoders' outputs — and the concat into the
delivered file means ~29 GB of segments and a ~29 GB result coexist, a peak of
~58 GB against today's ~55.5. See `docs/composite-performance.md` §7.

## 11. Not in scope

- Overlaying chat on top of the video instead of beside it, and any other
  frame layout. One shape, chosen deliberately.
- User-configurable chat appearance beyond text size — colours, font, badges,
  emotes, outline, timestamps. Deleted on purpose (§8); text size is the one
  exception, and §4/§8 say why.
- Compositing an already-downloaded VOD with an already-rendered chat. Every
  composite runs as part of a job that produced both inputs.
- Vertical or "shorts" layouts.
- Burned-in subtitles, alerts, or any other overlay.
