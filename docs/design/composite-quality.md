# Why the composited chat looked coarse

**Status:** investigated 2026-08-28/29 across sixteen VOD and clip samples.
The cause is settled and two fixes have shipped. The structural answer — §8 —
is designed and its blocking risk cleared, but not built.

**The complaint:** the rendered chat in a composite "just doesn't look that
good"; the type reads as coarse.

Everything here was measured against decoded frames rather than reasoned
about, per [`twitch-metadata.md`](../twitch-metadata.md) §7. §9 records three
measurement mistakes made along the way, because two of them produced
confident wrong answers first.

---

## 1. The answer

The chat column is **starved of bitrate by the composite encode**. Not the
renderer, not the font, not antialiasing, and — surprisingly — not the
intermediate encode either.

| stage | share of the chat column's final error |
|---|---|
| the chat renderer | none: its output is clean |
| intermediate encode (generation 1) | ~5% |
| **composite encode (generation 2)** | **~95%** |

And the bitrate a composite needs is **a property of the footage**, which no
metadata predicts. Across sixteen samples the requirement spans **7.5x** at
identical resolution and framerate — 5 to 38 Mbps at 1080p60.

Two changes shipped (§6). The structural answer is §8: it makes files
*smaller* on most content while fixing the starved parts.

---

## 2. What it is not

Four plausible causes, tested and eliminated. Recorded so nobody pays to
rediscover them.

### 2.1 Not the renderer, and not antialiasing

The leading hypothesis was subpixel antialiasing, and it had a real basis:
every text paint in `ChatRenderer.cs` (lines 99–101, and 2172) is built with

```csharp
LcdRenderText = true, SubpixelText = true,
IsAutohinted = true, HintingLevel = SKPaintHinting.Full
```

`LcdRenderText` is LCD subpixel AA — RGB fringes tuned for a physical panel,
and exactly wrong for video, because the fringes are chroma detail at the
finest spatial frequency and `yuv420p` halves chroma resolution on both axes.

**It is not actually happening.** `LcdRenderText` is a *request*; Skia honours
it only when the target surface declares a pixel geometry, and an offscreen
bitmap does not. On a lossless render of a real frame, **97.59% of pixels are
perfectly achromatic** (channel spread exactly 0). The sub-16 spread buckets
hold under a thousand pixels in the whole frame, and the ≥32 population is
just the coloured usernames and emotes. Skia fell back to grayscale AA.

Full hinting *is* applied and is not the Mac convention, but at 16px it is not
what the eye objects to: the lossless render at 4x has clean edges and
well-formed letterforms.

**None of it is reachable from the CLI anyway** — all 55 `chatrender` options
were checked and there is no AA or hinting flag. Changing it would be an
upstream patch, not an argument.

### 2.2 Not the intermediate encode

`h264_videotoolbox` supports **only** `yuv420p`/`nv12`, so an H.264
intermediate cannot avoid chroma subsampling. Alternatives, on a 30s window:

| intermediate | size | chroma error on usernames, generation 1 alone |
|---|---|---|
| `h264_videotoolbox` 12M yuv420p (current) | 1.24 MB | 11.14 |
| ProRes 4444 (`nv24`, 4:4:4) | 63.13 MB | 5.13 |
| FFV1 lossless (`bgra`) | 19.18 MB | 0 by definition |
| raw over a pipe (no file) | — | 0 |

ProRes is the intuitive choice and the worst one: 3x FFV1's size for *worse*
quality.

But measured through the whole chain against a real composite, **removing
generation one entirely buys 4.8%** (chroma error 17.79 → 16.94).

That retires an idea that looked strong.
[`composite-performance.md`](../composite-performance.md) §4.1 measured
raw-over-a-pipe as free in wall clock and worth 10.2 GB off the disk peak, and
it was rejected on coupling grounds. **Quality is not a new argument for it.**
The FIFO remains a disk-peak decision and nothing else.

### 2.3 Not fixable by `--outline`

The reasoning was appealing: a black stroke makes the glyph boundary a *luma*
edge, which 4:2:0 preserves, rather than a chroma edge, which it halves.
Measured slightly **worse** (18.52 against 17.79) and it does not look better.
The stroke is itself expensive to encode at a starved rate, so it competes
with the thing it was meant to protect.

### 2.4 Not the chroma floor, though that is real

Comparing a lossless render against the production intermediate:

| region | Y PSNR | Cb PSNR | Cr PSNR | mean chroma error |
|---|---|---|---|---|
| white message text | 36.9 | 54.5 | 44.2 | **0.19** |
| coloured usernames | 36.4 | **28.0** | **24.2** | **11.14** |

Luma is handled *identically* for both; the damage is entirely chroma and
lands on coloured usernames — 59x the error. A coloured name at 16px is almost
all chroma detail.

This is true, and it is **not the main event**. Chroma PSNR barely moves with
bitrate (Cb +1.6 dB, Cr +0.9 dB from 10 to 40 Mbps) because 4:2:0 is a
*resolution* loss that no bitrate restores. But the dominant artifact at a
starved rate is luma blocking and ringing, which bitrate fixes outright
(+8.8 dB on white text). Chroma subsampling is the residual you would notice
only after the rate is fixed.

**Judged on the chroma metric alone the fix looks pointless; judged on decoded
frames it is the whole difference.** That is the strongest argument here for
§10's rule about looking at pixels.

---

## 3. What it is: the composite encode, starved

Composite of a real 1824x1026@30 VOD, chat column measured against the
pristine chat render:

| Mbps | 6h | white text Y | Δ |
|---|---|---|---|
| 6 (the old floor) | 16 GB | 18.1 | |
| 8 | 21 GB | 19.7 | +1.5 |
| **10 (shipped then)** | 26 GB | 21.9 | +2.2 |
| 12 | 31 GB | 23.6 | +1.7 |
| 14 | 36 GB | 24.2 | **+0.6** |
| 16 | 41 GB | 25.9 | +1.6 |
| 20 | 52 GB | 27.6 | +1.7 |
| 24 | 62 GB | 28.5 | +0.9 |
| 40 | 103 GB | 30.7 | +2.2 |

Near-linear at roughly +1.5 dB per +2 Mbps, with no knee. **Bitrate is free in
time** — 3.13s at 16 Mbps against 3.58s at 40 Mbps — so the cost is bytes and
only bytes.

---

## 4. How much content varies, and why no constant works

Sixteen samples: static talking heads, IRL, 2D RPGs, open-world RPGs,
trailers, a DJ set, three shooters and two fighting games. Thirteen carried
enough chat to measure. "Required bpp" is what reaches a fixed quality target
of Y = 26 dB against the pristine render:

| sample | motion+detail | required bpp | at 1080p60 |
|---|---|---|---|
| zelda (2D, 30fps) | 17.9 | 0.034 | 5.0 Mbps |
| static | 10.5 | 0.048 | 7.1 |
| frankie (Chrono Trigger) | 11.5 | 0.070 | 10.3 |
| justchat | 17.6 | 0.072 | 10.7 |
| marzzzzy (trailers) | 18.5 | 0.073 | 10.8 |
| djclip (DJ visuals) | 22.1 | 0.081 | 12.0 |
| fighting game | 43.8 | 0.102 | 15.1 |
| leigh (FF7 battle) | 25.7 | 0.112 | 16.5 |
| overwatch | 32.7 | 0.114 | 16.8 |
| rpg (open world) | 17.2 | 0.123 | 18.2 |
| busy2 | 35.2 | 0.158 | 23.3 |
| fps2 | 28.5 | 0.177 | 26.2 |
| sf6 | 37.3 | 0.254 | 37.6 |

**A 7.5x spread at the same resolution and framerate.** That is the single
most important number in this document.

### 4.1 The source's advertised bitrate is worse than useless

The old formula's primary term was `StreamQuality.bitsPerSecond`, the m3u8's
`BANDWIDTH`. In this sample it is **anti-correlated with need**: both quiet
VODs advertise more (8.44, 8.56 Mbps) than both busy ones (6.36, 6.40). It
gave least to the streams that needed most.

`BANDWIDTH` is a peak describing the rendition's ceiling, not the difficulty
of the footage. Twitch transcodes to a flat target — delivered bitrate is
95–97% of advertised on every sample — so it carries no content information
at all.

### 4.2 Bits-per-pixel does not transfer across framerate either

The obvious replacement does not survive the same data: equivalent quality
needs ~0.36 bpp at 1824x1026**@30** but ~0.17 bpp at 1080p**60**. At 60fps
consecutive frames are more alike, so the same result costs half the bits per
pixel. A single constant over-serves 60fps or starves 30fps.

---

## 5. Can content difficulty be predicted? Partly

Cheap metrics — mean absolute frame difference (motion) and mean gradient
magnitude (detail) — computed by decoding at quarter resolution and 4 fps.
Under 10 seconds for a six-hour VOD against a ~75-minute composite.

Against **required bpp**, on the thirteen usable samples:

| predictor | Pearson | Spearman |
|---|---|---|
| motion | +0.59 | +0.69 |
| detail | +0.42 | +0.41 |
| **motion + detail** | **+0.65** | **+0.68** |
| motion x detail | +0.64 | +0.69 |

Spearman ~0.68 is enough to **rank** and nowhere near enough to **set a rate**.
The clearest failure: `rpg` (m+d 17.2) needs 0.123 bpp while `zelda` (17.9)
needs 0.034 — indistinguishable metrics, **3.6x** different requirements.

**So silent per-VOD auto-selection is not supportable**; it would be badly
wrong in both directions on cases like that. §8 does not have this problem.

---

## 6. What shipped

### 6.1 The rate comes from the output frame

`compositeBitrateMbps()` takes no argument. `reencodeHeadroom` and
`maxBitsPerPixel` are gone, along with the trap where raising the ceiling
moved one case from 10 to 11.32 Mbps and then stopped because the other term
had become binding.

```
mbps = max(10, outputWidth x videoHeight x videoFramerate x 0.12 / 1e6)
```

### 6.2 The constant is 0.12, and it is a percentile

The median requirement across the thirteen samples is 0.102. **0.12 covers 9
of 13**; 0.10 covered 6. The four it misses are the busiest — a fighting game
and two shooters — needing up to 2.1x more.

It errs high because the two errors are not symmetric: **over-serving costs
disk, which is predictable and deletable; under-serving costs quality, which
is unrecoverable without redoing the whole job.**

It is not an optimum. It is a percentile of a distribution measured at one
quality bar, and **the bar moves the answer further than the percentile does**
— at Y = 24 the same constant covers ~85% of these samples, at Y = 28 nearer
40%. Anyone revisiting this should decide what "acceptable" means before
arguing about percentiles.

The floor rose from 6 to 10. Six measured 18.1 dB, visibly mush, and a floor
that cannot produce an acceptable frame is not a floor.

### 6.3 Dispersion is always on

Unrelated to bitrate, found in the same investigation, shipped.

A Twitch API change in November 2022 made downloaded chat carry only
whole-second timestamps. On a heavy-chat window (1,253 messages over 180s),
**100% land exactly on a whole second** and 138 separate seconds carry four or
more at the identical instant — the worst carrying **fifteen**.

| | update events | within 0.1s of a whole second |
|---|---|---|
| without `--dispersion` | 262 | **72.9%** |
| with `--dispersion` | 527 | **30.0%** |

It doubles the distinct update moments and spreads them through the second.
Across the fifteen-message second the undispersed render holds **five
consecutive frames identical** and then changes everything at once.

Always on, not a `RenderRequest` field, on the reasoning
[`compositing.md`](compositing.md) used to narrow the intake: nobody wants
artificially clumped timestamps. No measurable render cost.

---

## 7. `--avatars`, and why it is now less attractive

[`cli-dependency.md`](cli-dependency.md) §7 flagged `--dispersion` and
`--avatars` together as cheap things to try before concluding anything about
the renderer. Dispersion shipped; avatars did not, and there is now a reason
for caution that did not exist then.

Avatars are **photographs** — high spatial detail, a different one per user,
injected directly into a chat column that §3 shows is already losing the bit
competition. It would consume the headroom §6.2 just bought. Measure what it
costs the composite before adopting it.

---

## 8. The structural answer: allocate per section

### 8.1 The requirement varies within one stream

Per-minute `motion + detail` across a contiguous 20-minute stretch:

| | spread | CV |
|---|---|---|
| FF7 Remake | 2.5x | 0.25 |
| Overwatch | 2.8x | 0.19 |
| IRL | 1.8x | 0.15 |
| **between 16 streams** | **4.2x** | **0.39** |

Within-stream variance is about half the between-stream variance, and far from
negligible.

**And it is need, not merely metric.** Two adjacent two-minute windows of the
same FF7 stream, two minutes apart:

| window | m+d | required bpp |
|---|---|---|
| 9600s, quiet | 11.2 | **0.059** |
| 9720s, busy | 25.9 | **0.110** |

Metric ratio 2.32x, measured need ratio **1.87x**. The metric tracks the
requirement *within* a stream in direction and rough magnitude — the
assumption this design rests on, tested rather than asserted.

### 8.2 It makes files smaller, not larger

Applying a two-point calibration (`need ≈ 0.020 + 0.0035 x (m+d)`) to the
per-minute profiles:

| stream | flat 0.12 | per-section mean | file size | at the flat rate |
|---|---|---|---|---|
| FF7 Remake | 0.120 | 0.091 | **−24%** | 100% of minutes over-served |
| IRL | 0.120 | 0.075 | **−38%** | 100% of minutes over-served |
| Overwatch | 0.120 | 0.137 | +14% | **84% under-served** |

**Per-section allocation is not a quality feature that costs disk. It is a
disk feature that also fixes quality.** Two of three streams get materially
smaller files at unchanged quality, because every minute of them is paying for
bits it cannot use. The third grows — and it is the one that looks bad.

It also dissolves the dilemma §4 ends on. A flat constant must choose between
wasting space on quiet content and starving busy content because it cannot
tell them apart. Allocating per section never has to: a quiet stream is simply
one whose sections are all quiet.

And it repairs §5's weakness. Absolute classification needs a threshold
calibrated across all content, which +0.68 cannot supply. **Ranking sections
within one stream needs no threshold at all**, and a proportional allocation
inside a user-chosen total budget would use only that ranking, never the
absolute fit — the weakest part of all of this.

### 8.3 The blocking risk is cleared

`-c copy` concat requires consistent codec parameters, so the question was
whether `h264_videotoolbox` holds profile and level constant across a wide
bitrate range. **It does**: profile High, level 5.0, identical at 6, 12, 18,
25, 40 and 60 Mbps at 2280x1080@60.

Verified by assembling, not by reading headers. Joining a 6M, a 60M and an 18M
piece gives exit 0, duration exactly 3:00.05 against 3 x 60.02, a clean full
decode, exactly **10,803 frames** against 3 x 3601, and correct seeking into
the middle piece.

### 8.4 What it still costs

- Sections must be minutes, not Twitch's ~10s segments: 2,160 encoder
  invocations for a six-hour job is absurd.
- Section boundaries must land on keyframes.
- It touches resume, progress reporting and the fragment index — the three
  things [`resume.md`](resume.md) and
  [`fragmented-output.md`](fragmented-output.md) were most careful about.
- The calibration in §8.2 is two points; its absolute levels are rough.

**Written up as [`composite-sections.md`](composite-sections.md)**, which
settles the section length by measurement (60 seconds: +3.6% wall clock, no
adaptation lost), keeps the analysis out of a new `StepKind`, and identifies
frame-exactness across 360 boundaries as the most likely subtle bug.

---

## 9. Three measurement mistakes, and what they cost

Recorded because two produced confident, wrong, *written-down* answers before
being caught.

**Sampling one frame.** The composite's chat lags by under 0.2s from the
`fps=30->60` resample. Comparing a single composite frame against the same
frame index of the pristine render puts the two on opposite sides of any
message appearing near that instant: 24.3 dB at chat frame 3355, **10.4 dB** at
3360. One sample scored 2.9 dB, which is not a quality measurement. Worse, the
failure probability scales with **chat density**, so the harness was partly
measuring how busy the chat was rather than how hard the video is.

This produced a published finding — "motion fails, detail works" — that
**inverts** once fixed: motion is the stronger predictor and detail alone is
weak. Fixed by sampling five instants per window and searching ±10 frames
around each for the best match, taking the median.

**Comparing at fixed megabits.** 10 Mbps is a different bits-per-pixel at
every geometry: 1080p30 gets twice what 1080p60 does, and one 1152x744@30
sample was getting five times. Two samples were called "easy" when they had
simply been handed more budget. Everything is now measured at fixed
bits-per-pixel of each sample's own output frame.

**Windows too short.** At 150s several samples carried fewer than ten chat
messages and one carried none. Raised to 300s; three samples are still too
thin (under ~2000 text pixels) and are excluded rather than averaged in.

**A false alarm worth recording.** An early encoder test dropped
`setpts=PTS-STARTPTS` and encoded a source starting at 0.666s;
`h264_videotoolbox` aborted at 27.4s of a 60s input with `Unexpected end of SEI
NAL Unit parsing type`. **The shipping composite is unaffected** — it always
resets PTS on both inputs and produces the full duration. The lesson is to test
the argv the app actually sends.

---

## 10. Reproducing this

The bundled FFmpeg has no PNG encoder (LGPL build), so frames come out as raw
RGB and something has to read them — hence `pillow` and `numpy` in
`requirements-dev.txt`.

```bash
# a chat window and its video
build/helper/TwitchDownloaderCLI chatdownload --banner=false --collision Overwrite \
  --id <id> -b <start> -e <end> -o chat.json
build/helper/TwitchDownloaderCLI videodownload --banner=false --collision Overwrite \
  --id <id> -b <start> -e <end> -q 1080p60 \
  --ffmpeg-path build/ffmpeg/ffmpeg -o video.mp4

# the pristine reference: lossless, no chroma subsampling
build/helper/TwitchDownloaderCLI chatrender --banner=false --collision Overwrite \
  -i chat.json -o chat-lossless.mkv --ffmpeg-path build/ffmpeg/ffmpeg \
  -w <chatWidth> -h <videoHeight> --framerate <chatFramerate> --font-size <size> \
  '--output-args=-c:v ffv1 -pix_fmt bgra "{save_path}"'

# a composite at a chosen bits-per-pixel of ITS OWN output frame
build/ffmpeg/ffmpeg -i video.mp4 -i chat.mp4 -filter_complex \
  "[0:v]setpts=PTS-STARTPTS[v];[1:v]setpts=PTS-STARTPTS,fps=<fps>[c];[v][c]hstack=inputs=2[out]" \
  -map "[out]" -an -c:v h264_videotoolbox -b:v <N>M -pix_fmt yuv420p out.mp4
```

Segment the pristine frame into white text (`spread < 12`) and coloured
usernames (`spread >= 40`) above the `#111111` background, then compare each
region against the same region of the composite's chat column. Whole-frame
numbers are dominated by the background and the video half, and move for
reasons unrelated to the text.

Three rules §9 earned:

1. **Sample several instants and search for alignment.** One frame is not a
   measurement.
2. **Compare at fixed bits-per-pixel, never fixed megabits.**
3. **Look at the frames as well as the numbers.** §2.4 is the case for this:
   the chroma metric alone says the shipped fix was not worth making.

---

## 11. Next

1. **Per-section allocation (§8).** Designed in
   [`composite-sections.md`](composite-sections.md); not built. Two things
   must be settled first: widen the two-point calibration, and verify seek
   cost at a five-hour offset.
2. **Widen §5's sample if the metric is to drive anything absolute.** Ten more
   VODs would tell you whether +0.68 improves or is a ceiling. Not needed for
   §8, which uses ranking only.
3. **Measure `--avatars` against the composite** before adopting it (§7).

**Not next, and why:** a user-facing quality tier. It converts a question we
could answer into one asked at intake, before the user has seen any output to
have an opinion about. If §8 lands, the tier becomes a total-size budget
instead — a question people can actually answer.
