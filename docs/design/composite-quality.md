# Why the composited chat looks coarse, and what to do about it

**Status:** investigated 2026-08-28 across four VODs. The cause is settled
(§1–§6). §7.1 has **landed**; the rest is open, and §11 says what to do next.
**Question:** the rendered chat in a composite "just doesn't look that good" —
the type reads as coarse. Is that the renderer, or the encoder?

Everything here was measured against decoded frames, per
[`twitch-metadata.md`](../twitch-metadata.md) §7. Where something is unverified
it says so.

---

## 1. The answer, first

It is the **composite encode**, and specifically that it is bitrate-starved.
It is not the renderer, not the font, not antialiasing, and — surprisingly —
almost not the intermediate encode either.

| stage | share of the chat column's final chroma error |
|---|---|
| the chat renderer itself | none — output is clean |
| intermediate encode (generation 1) | **~5%** |
| composite encode (generation 2) | **~95%** |

Three plausible-sounding fixes are worth **nothing** here, and each was tried:
a lossless intermediate, a ProRes 4:4:4 intermediate, and `--outline`.

And the amount of bitrate needed is **a property of the footage, not of the
stream's metadata** (§9). Two 1080p60 VODs measured 11 dB apart at the same
bitrate. Worse, the formula *was* keyed to the source's advertised bandwidth,
which in this sample is *anti-correlated* with need: it gave the least to the
streams that need the most. That was a bug independent of everything else here,
and §7.1 has removed it — the rate now comes from the composite frame's own
pixel rate. Where that rate should sit is still open.

---

## 2. The renderer is not the problem

The hypothesis was subpixel antialiasing. It had a real basis: every text
paint in `ChatRenderer.cs` (lines 99–101, and again at 2172) is built with

```csharp
LcdRenderText = true, SubpixelText = true,
IsAutohinted = true, HintingLevel = SKPaintHinting.Full
```

`LcdRenderText` is LCD subpixel AA — RGB-striped fringes tuned for a physical
panel, and exactly wrong for a video frame, because the fringes are chroma
detail at the finest spatial frequency and `yuv420p` halves chroma resolution
on both axes.

**It is not actually happening.** `LcdRenderText` is a *request*; Skia honours
it only when the target surface declares a pixel geometry, and the offscreen
bitmap here does not. Measured on a lossless render of a real frame:

| channel spread (max−min) | pixels | share |
|---|---|---|
| exactly 0 (perfectly neutral) | 379,419 | **97.59%** |
| 1–15 | ~967 | 0.25% |
| ≥32 | 7,787 | 2.00% |

If subpixel AA were active, every white glyph edge would carry a fringe.
Instead the sub-16 buckets hold under a thousand pixels in the whole frame,
and the ≥32 population is just the coloured usernames and emotes. Skia fell
back to grayscale AA.

Full hinting *is* applied and is not the Mac convention, but at the sizes we
render (16px at 1080p — `chatWidth / 22.5`) it is not what the eye is
objecting to. The lossless render, zoomed 4×, has clean edges and well-formed
letterforms.

**None of this is reachable from the CLI anyway.** All 55 `chatrender` options
were checked; there is no AA or hinting flag. If the renderer ever does need
changing here, it is an upstream patch, not an argument.

---

## 3. What the encode does, and to what

Same frame, lossless render versus the production intermediate
(`h264_videotoolbox -b:v 12M -pix_fmt yuv420p`):

| region | Y PSNR | Cb PSNR | Cr PSNR | mean chroma err |
|---|---|---|---|---|
| white message text | 36.9 | 54.5 | 44.2 | **0.19** |
| coloured usernames | 36.4 | **28.0** | **24.2** | **11.14** |

Luma is handled *identically* for both. The damage is entirely chroma and it
lands almost entirely on coloured usernames — 59× the error, 20 dB worse. A
coloured name at 16px is almost entirely chroma detail, and 4:2:0 throws half
of it away on each axis.

That finding is real but, as §4 shows, it is not where the visible damage
comes from.

---

## 4. The intermediate barely matters — 4.8%

`h264_videotoolbox` supports **only** `yuv420p`/`nv12`. There is no 4:4:4
H.264 on this encoder, so the intermediate cannot avoid subsampling while
staying H.264. Alternatives, all measured on the same 30s window:

| intermediate | size | chroma err on usernames (gen 1 alone) |
|---|---|---|
| `h264_videotoolbox` 12M yuv420p (current) | 1.24 MB | 11.14 |
| ProRes 4444 (`nv24`, 4:4:4) | 63.13 MB | 5.13 |
| FFV1 lossless (`bgra`) | 19.18 MB | 0 by definition |
| raw over a pipe (no file) | — | 0 |

ProRes is the intuitive choice and the worst one: 3× FFV1's size for *worse*
quality.

But measured **through the whole chain**, against the pristine render, on a
real composite with real footage competing for bits:

| pipeline | Y | Cb | Cr | chroma err |
|---|---|---|---|---|
| gen 2 only (lossless intermediate) | 24.3 | 25.0 | 22.1 | 16.94 |
| gen 1 + gen 2 (production, today) | 23.8 | 24.2 | 21.7 | 17.79 |

**Removing generation one entirely buys 4.8%.**

This matters beyond this document, because it retires an idea that looked
strong. [`composite-performance.md`](../composite-performance.md) §4.1
measured raw-over-a-pipe at 48.5s against a 48.4s baseline — free — and noted
it takes 10.2 GB off the disk peak. It was rejected on coupling grounds when
the only argument for it was speed. Quality is **not** a new argument for it.
The FIFO remains a disk-peak decision and nothing more.

---

## 5. The bitrate curve

Composite of a real 1824×1026@30 VOD, chat column measured against the
pristine chat render, same frame throughout:

| Mbps | 30s | 6h | white text Y | colour px Y | Δ white |
|---|---|---|---|---|---|
| 6 (`minimumBitrateMbps`) | 22 MB | 16 GB | 18.1 | 20.5 | |
| 8 | 30 MB | 21 GB | 19.7 | 21.6 | +1.5 |
| **10 (shipped today)** | 37 MB | 26 GB | 21.9 | 23.8 | +2.2 |
| 12 | 44 MB | 31 GB | 23.6 | 25.1 | +1.7 |
| 14 | 52 MB | 36 GB | 24.2 | 25.7 | **+0.6** |
| 16 | 59 MB | 41 GB | 25.9 | 27.1 | +1.6 |
| 20 | 74 MB | 52 GB | 27.6 | 28.1 | +1.7 |
| 24 | 88 MB | 62 GB | 28.5 | 29.5 | +0.9 |
| 40 | 146 MB | 103 GB | 30.7 | 31.2 | +2.2 |

Two things this says:

**There is no knee.** Roughly +1.5 dB per +2 Mbps, near-linear across the
whole range. No setting is obviously correct *on this VOD* — it is a continuous
trade against disk. §9 then shows the curve's steepness is itself a property of
the footage, which is what rules out picking a single better constant.

**14 is a trap.** It is the only step on the curve that buys almost nothing
(+0.6 dB for the same +5 GB every other step costs). The honest choices are 12
or 16.

**Bitrate is free in time.** 3.13s at 16 Mbps against 3.58s at 40 Mbps — 14%
more time for 4× the bits. The cost is bytes and only bytes.

### What bitrate does and does not fix

Chroma PSNR barely moves across that whole range (Cb +1.6 dB, Cr +0.9 dB from
10 to 40 Mbps), because 4:2:0 is a *resolution* loss and no bitrate restores
detail that was never encoded.

**Do not conclude from that that bitrate does not help.** It does, a lot. The
dominant artifact at 10 Mbps is luma blocking and ringing, which bitrate fixes
outright (+8.8 dB on white text). Chroma subsampling is the residual you would
notice only after the rate is fixed. Judged on the chroma metric alone this
change looks pointless; judged on decoded frames it is the whole difference.
That is a good argument for §10's rule about looking at pixels.

---

## 6. The trap in the constants — historical

*Describes the formula as it stood before §7.1. Kept because it explains why
raising the ceiling alone would not have worked, which is the fix a reader
reaches for first.*

The two constants in `CompositeGeometry.compositeBitrateMbps` interacted, and
the one the comments drew attention to was not always the one that bound:

```
mbps    = source × pixelRatio × reencodeHeadroom
ceiling = outputWidth × videoHeight × videoFramerate × maxBitsPerPixel
result  = max(minimumBitrateMbps, min(mbps, ceiling))
```

On the 1824×1026@30 VOD: `mbps` = 11.32, `ceiling` = 10.00 → **the ceiling
binds**.
On a 1920×1080@60 VOD at 8.44 Mbps: `mbps` = 15.04, `ceiling` = 22.16 → **the
headroom binds**.

So raising `maxBitsPerPixel` alone moves the first case to 11.32 Mbps and then
stops, and does nothing at all to the second. Reaching 16 or 24 requires
raising `reencodeHeadroom`. The ceiling's real job is narrower than it looks:
it stops a *peak* `BANDWIDTH` reading from producing 36 Mbps, and it should
keep doing exactly that and nothing more.

---

## 7. What to change

### 7.1 The one unambiguous bug

**Stop deriving the rate from the source's advertised bandwidth.** §9 shows it
is anti-correlated with need across four samples: both quiet VODs advertise
more than both busy ones, so `reencodeHeadroom × source` hands bits to the
streams with nothing to spend them on and withholds them from the streams that
are visibly starved. `BANDWIDTH` is a peak; it describes the rendition's
ceiling, not the footage.

This is wrong under every design below, so it can be fixed without settling
any of them.

`minimumBitrateMbps` should also rise from 6. Six was never capable of carrying
a chat column — 18.1 dB, visibly mush. A floor that cannot produce an
acceptable frame is not a floor.

### 7.2 Three candidate designs, none yet chosen

**(a) Do nothing else.** Defensible. The output is only clearly bad on
high-detail footage, and §9 now records exactly when and why.

**(b) Content-blind, tuned for the modal VOD.** Replace the source term with a
framerate-aware baseline set near what busy footage needs. This is a Twitch VOD
downloader; most of what goes through it is gameplay, and gameplay is the case
that looks bad. Quiet streams then overpay disk for nothing — the cost of
having no detection.

**(c) Content-adaptive** — §7.3 and §7.4. Strictly better if the signal holds,
and the only option that spends disk where it is actually needed.

A user-facing quality tier was drafted here and is **not** recommended as the
primary answer. It converts a question we could answer into one the user is
asked at intake, before they have seen any output to have an opinion about. If
detection ever lands, the tier survives only as an override on a decision
already made — and shown, via the size estimate the intake already displays.

### 7.3 Sniffing the source: motion fails, detail works

Measured on all four samples, decoding at quarter resolution and 4 fps:

| VOD | motion (mean │Δframe│) | **detail** (mean gradient) | needs |
|---|---|---|---|
| Eweaselbeth, game | 8.62 | **10.90** | HIGH |
| LeighXP, FF7 battle | 11.68 | **10.30** | HIGH |
| marzzzzy, talking | 11.59 | **6.37** | low |
| FrankieLollia, Chrono Trigger | 1.25 | **8.15** | low |

**Motion is useless.** marzzzzy (11.59) and LeighXP (11.68) are
indistinguishable and need opposite things — trailers cut fast but are smooth.

**Spatial detail separates 4/4**, with a gap between 8.15 and 10.30, and the
mechanism is sensible: high-frequency detail is what is expensive to encode, so
it is what takes bits from the chat column.

Cost: ~6s for a 180s window at quarter resolution. Sampling sixty one-second
windows across a six-hour VOD would be 5–10s against a ~75-minute composite.
Effectively free.

**Four samples and a threshold fitted to them is overfitting**, and this
document has already made that mistake once (§9). An absolute threshold needs
roughly ten more VODs before it can be trusted to decide anything silently.

### 7.4 Per-section allocation, and why it rescues a weak signal

The bitrate is one number for the whole encode. `-b:v` is an *average*, so the
encoder already gives hard frames more bits than easy ones — what is fixed is
the budget, not its distribution. On busy footage the encoder is redistributing
a shortage.

Budgets could vary per section. A six-hour stream with a twenty-minute boss
fight currently chooses between paying a high rate for six hours or accepting
mush for twenty minutes. Per-section budgets spend the disk only where it is
needed, which is the whole objection to raising the rate globally.

**The important part is what this does to the measurement problem.** Absolute
classification — "is this VOD busy?" — needs a threshold calibrated across
every kind of content, which four samples cannot supply. Ranking sections
*within one stream* needs no such thing: "this ten minutes is busier than that
ten minutes" is self-calibrating, and a mediocre metric still ranks correctly.
The objection in §7.3 does not apply to §7.4.

Plumbing that already exists: `.assemble` concatenates pieces with `-c copy`,
built for resume (`resume.md`). Different bitrates concatenate fine — bitrate
is not a stream parameter.

Not free, and not yet verified:

- Whether `h264_videotoolbox` holds profile and level constant across a wide
  bitrate range. If it does not, `-c copy` concat breaks.
- Section boundaries must land on keyframes.
- Sections must be minutes, not Twitch's ~10s segments: 2,160 encoder
  invocations for a six-hour job is absurd.
- It touches resume, progress reporting, and the fragment index — the three
  things `resume.md` and `fragmented-output.md` were most careful about.

This deserves its own design document rather than being smuggled in here.

---

## 8. Rejected, with reasons

- **Lossless or 4:4:4 intermediate** — §4. Worth 4.8%.
- **Raw over a FIFO** — same 4.8%. Still defensible on disk-peak grounds
  (`composite-performance.md` §8), never on quality.
- **`--outline`** — the reasoning was that a black stroke makes the glyph
  boundary a *luma* edge, which 4:2:0 preserves, instead of a chroma edge,
  which it halves. Measured slightly **worse** (18.52 against 17.79) and does
  not look better: the stroke is itself expensive to encode at a starved rate,
  so it competes with the thing it was meant to protect.
- **Raising `maxBitsPerPixel` alone** — §6. Stops at the headroom.
- **A renderer change for antialiasing** — §2. Not the cause, and not
  reachable from the CLI.

---

## 9. The second sample, which contradicts the first

§5's curve is one VOD. A second — `2859050150`, marzzzzy, 1920×1080@60 at
8.44 Mbps, 29 messages/minute, a three-minute window at 2h30m — behaves
**completely differently**:

| Mbps | 3 min | 6h | white text Y | colour px Y | chroma | Δ white |
|---|---|---|---|---|---|---|
| 10 | 224 MB | 26 GB | 29.5 | 20.5 | 17.81 | |
| 12 | 269 MB | 31 GB | 30.1 | 20.6 | 17.50 | +0.6 |
| **15 (shipped today)** | 335 MB | 39 GB | 30.3 | 20.6 | 17.44 | +0.2 |
| 20 | 445 MB | 52 GB | 30.6 | 20.6 | 17.33 | +0.3 |
| 25 | 556 MB | 65 GB | 30.7 | 20.6 | 17.23 | +0.2 |

**+1.2 dB across 2.5× the bytes**, against +8.8 dB on the first VOD. The 10 and
25 Mbps frames are visually indistinguishable. This VOD is already fine at 10,
and today's formula is giving it 15.

### Why

The video half and the chat column compete for one rate allocation. The first
VOD is game footage — high motion, soaking bits, starving the chat column at
10 Mbps. The second is a talking-and-watching stream — low motion, cheap to
encode, leaving the chat column well fed at any rate tested.

**So the bitrate a composite needs is a function of how busy the video is, and
nothing in the metadata predicts that.** `BANDWIDTH` is a peak, not a measure
of motion. Today's formula is keyed to it, which is why it is wrong in both
directions at once: 10 Mbps for the VOD that needed 20, and 15 Mbps for the
VOD that needed 10.

**This kills a blanket constant raise.** Applied to the second VOD, the §7
"Good" tier costs 26 → 39 GB and buys nothing visible.

### A caveat on comparing the two tables

Absolute PSNR is **not** comparable across the two VODs. The sampled frames
carry very different amounts of text (10,344 white pixels against 40,859), and
a sparse frame is mostly thin antialiased edges — the hardest pixels to
reproduce — while a dense one has solid interiors that encode perfectly. That
alone inflates the second VOD's numbers.

What *is* comparable, and what the argument rests on, is the **within-VOD
trend**: does more bitrate help this VOD? Both trends were confirmed by looking
at decoded crops, and both agree with their metrics.

### Four VODs, and the axis is content

Two more samples, both 1920×1080@60 — so resolution and framerate are
controlled and only the footage differs. White-text Y against the pristine
render, same method throughout:

| VOD | footage | source | today gives it | Y @ 10 Mbps | 10 → 25 |
|---|---|---|---|---|---|
| Eweaselbeth `1480816483` | game, 1824×1026@30 | 6.36 Mbps | 10 Mbps | 21.9 | +8.8 (to 40) |
| **LeighXP `2840074660`** | FF7 battle, particles | 6.40 Mbps | **11 Mbps** | **20.1** | **+8.0** |
| marzzzzy `2859050150` | talking / trailers | 8.44 Mbps | 15 Mbps | 29.5 | +1.2 |
| **FrankieLollia `2838858700`** | Chrono Trigger, 2D | 8.56 Mbps | **15 Mbps** | **31.1** | **+1.0** |

The two 1080p60 rows differ by **11 dB at identical bitrate, resolution and
framerate**. That is content and nothing else. High-motion footage soaks the
rate allocation and starves the chat column; low-motion footage leaves it well
fed at any rate tested.

**The source's advertised bitrate is anti-correlated with need in this
sample.** Both quiet VODs advertise *more* (8.44, 8.56) than both busy ones
(6.36, 6.40), so the formula hands the streams that need bits the least and
the streams that need nothing the most. `BANDWIDTH` is a peak; it says nothing
about motion. Keying the primary term to it is not merely imprecise here — it
is backwards.

### Bits per pixel does not transfer either

The obvious replacement — a flat bits-per-pixel target on the output frame —
does not survive the same data. Acceptable quality needed ≈0.36 bpp on the
1824×1026@30 sample but ≈0.17 bpp on the 1080p**60** busy one. At 60fps
consecutive frames are more alike, so fewer bits per pixel buy the same
result. A single bpp constant would over-serve 60fps or starve 30fps.

Four samples across two framerate classes is not enough to fit a
framerate-dependent curve, and pretending otherwise would be the same mistake
as §9's first draft.

### Sixteen samples, and a measurement bug worth recording

§7.3's motion/detail table was produced by a **broken harness** and its
conclusion — "motion fails, detail works" — is **retracted**. With the bug
fixed the finding inverts: motion is the stronger predictor and detail alone
is weak.

**The bug.** One frame was sampled from the composite and compared against the
same frame index of the pristine render. But the composite's chat lags by
under 0.2s (the `fps=30->60` resample), so when a message appeared near the
sampled instant the two landed on opposite sides of it:

| chat-render frame | PSNR against the composite's frame |
|---|---|
| 3355 | 24.3 dB |
| 3360 | **10.4 dB** — one message appeared here |

One sample scored 2.9 dB, which is not a quality measurement. Worse, the
failure probability scales with **chat density**, so the harness was partly
measuring how busy the chat was rather than how hard the video is.

Fixed by sampling five instants per window and searching ±10 frames around
each for the best match, taking the median. Windows went 150s -> 300s, since
several samples had fewer than ten messages in 150s. Three samples remain too
thin to trust (fewer than ~2000 text pixels) and are excluded.

Two other corrections the wider set forced: samples were being compared at a
fixed **megabit** rate, which is a different bits-per-pixel at every geometry —
1080p30 gets twice what 1080p60 does, and one 1152x744@30 sample was getting
five times. Everything below is measured at a fixed bits-per-pixel of each
sample's own output frame.

### What content actually costs

Thirteen usable samples, spanning static talking heads to Street Fighter 6.
"Required bpp" extrapolates from two measured points to a fixed quality target
of Y = 26 dB against the pristine render:

| sample | m+d | required bpp | at 1080p60 |
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

**The requirement spans 7.5x — 5 to 38 Mbps at the same resolution and
framerate.** That is the single most important number in this document. No
constant can serve both ends, and the spread is content, not geometry.

**The shipped 0.10 bpp is the median of that distribution** (the median
requirement is 0.102). That was chosen in §7.1 purely to avoid regressions, so
it is luck rather than judgement — but it means roughly half of real content is
adequately served today, and the other half is not.

Useful framing for choosing a default: covering ~70% of content needs ~0.12
bpp, ~90% needs ~0.18, and everything in this sample needs 0.25. At 1080p60
those are 18, 27 and 38 Mbps — about 47, 70 and 98 GB for six hours.

### Can it be predicted? Partly, and not well enough

Against **required bpp**, on the thirteen usable samples:

| predictor | Pearson | Spearman |
|---|---|---|
| motion | +0.59 | +0.69 |
| detail | +0.42 | +0.41 |
| motion + detail | **+0.65** | **+0.68** |
| motion x detail | +0.64 | +0.69 |

Spearman ~0.68 is enough to **rank** content and nowhere near enough to **set
a rate**. The clearest failure: `rpg` (m+d 17.2) needs 0.123 bpp while `zelda`
(m+d 17.9) needs 0.034 — indistinguishable metrics, **3.6x** different
requirements. Any silent per-VOD auto-selection would get cases like that
badly wrong in both directions.

So §7.2(c) as *per-VOD detection* is not supportable. §7.4 per-**section**
allocation is untouched by this, because ranking is exactly what a +0.68
Spearman is good for, and it never needs an absolute threshold.

**Unknown, and now the interesting question:** every measurement here is one
window per VOD, so nothing in this document says how much the requirement
varies *within* a single stream. That variance is precisely what per-section
allocation would exploit, and it has not been measured.

### Constant quality: tried, not understood

`h264_videotoolbox` accepts `-q:v`, and content-adaptive allocation is exactly
what this problem wants. But at equal `q:v` the two VODs land **8× apart** in
resulting bitrate (14.0 against 1.7 Mbps at `q:v 20`), only 2.2× of which the
pixel-rate difference explains. Until that is understood it is not a solution,
just a different unexplained number. Recorded as a lead, not a plan.

## 9b. Still not verified

- The tier figures in §7 for 1920×1080@60 are computed from the formula, not
  measured for quality.
- Nothing here says how the composite looks in motion. Every measurement is a
  still frame; blocking that is invisible in a still can crawl distractingly at
  30fps, and vice versa.

---

## 10. Reproducing this

The bundled FFmpeg is built without a PNG encoder, so frames come out as raw
RGB and something has to read them — hence `pillow` and `numpy` in
`requirements-dev.txt`.

```bash
# a chat window and its video
build/helper/TwitchDownloaderCLI chatdownload --banner=false --collision Overwrite \
  --id <id> -b <start> -e <end> -o chat.json
build/helper/TwitchDownloaderCLI videodownload --banner=false --collision Overwrite \
  --id <id> -b <start> -e <end> -q <quality> \
  --ffmpeg-path build/ffmpeg/ffmpeg -o video.mp4

# the pristine reference: lossless, no chroma subsampling
build/helper/TwitchDownloaderCLI chatrender --banner=false --collision Overwrite \
  -i chat.json -o chat-lossless.mkv --ffmpeg-path build/ffmpeg/ffmpeg \
  -w <chatWidth> -h <videoHeight> --framerate <chatFramerate> --font-size <size> \
  '--output-args=-c:v ffv1 -pix_fmt bgra "{save_path}"'

# a composite at a chosen rate, then one frame of each as raw RGB
build/ffmpeg/ffmpeg -i video.mp4 -i chat.mp4 -filter_complex \
  "[0:v]setpts=PTS-STARTPTS[v];[1:v]setpts=PTS-STARTPTS,fps=<fps>[c];[v][c]hstack=inputs=2[out]" \
  -map "[out]" -an -c:v h264_videotoolbox -b:v <N>M -pix_fmt yuv420p out.mp4
build/ffmpeg/ffmpeg -i out.mp4 -vf "select=eq(n\,880)" -frames:v 1 \
  -pix_fmt rgb24 -f rawvideo frame.raw
```

Segment the pristine frame into white text (`spread < 12`) and coloured
usernames (`spread >= 40`) above the `#111111` background, then compare each
region's Y/Cb/Cr against the same region of the composite's chat column. The
segmentation matters: a whole-frame number is dominated by background and by
the video half, and moves for reasons that have nothing to do with the text.

**Look at the frames as well as the numbers.** §5 is the case for that: the
chroma metric alone says this change is not worth making.

---

## 11. Next steps, in the order they are worth doing

**1. Fix the anti-correlation (§7.1). — DONE.** `compositeBitrateMbps()` now
takes no argument and derives the rate from the composite frame's own pixel
rate at **0.10 bits per pixel**, with the floor raised from 6 to **10**.

`0.10` is a **no-regression value, not an optimum**: it was chosen so that no
measured case gets less than it did before. 1080p60 goes 11 → 15 where the
source was starving it and stays at 15 elsewhere; 1824×1026@30 stays at 10;
720p60 rises off the old 6. The starved 1080p60 case gains a measured +3.3 dB.

Explicitly **not** an answer to where the operating point belongs — §9 shows a
single bits-per-pixel constant cannot serve 30fps and 60fps equally, and four
VODs are not enough to fit one. That is step 3.

**2. Decide (a), (b) or (c) from §7.2.** This is a product judgment about
whether gameplay is the modal VOD, not a technical one, and the measurements
above are all the input it needs.

**3. If (c): widen the sample before trusting a threshold.** Ten more VODs
chosen for contrast — variety streams, pixel art, webcam-only, high-particle
gameplay — run through the same sweep. The harness is one script invocation per
VOD; the expensive part is already built. What this decides is whether §7.3's
detail metric holds up outside the four VODs that suggested it.

**4. Only then, per-section allocation (§7.4), as its own design.** It is the
best answer and the most invasive one. Verify the `-c copy` concat holds across
bitrates *first* — if `h264_videotoolbox` shifts level, the whole approach
needs a different assembly strategy and it is better to know that on day one.

### Deliberately not next

- **A user-facing quality tier.** §7.2. It is a fallback if detection fails,
  not a goal.
- **Anything about the intermediate encode.** §4. Worth 4.8%.
- **Anything about the renderer.** §2. It is not the problem, and the settings
  that looked suspicious are not reachable from the CLI anyway.
- **Chasing the chroma floor.** `h264_videotoolbox` is 4:2:0-only and the
  delivered file has to play everywhere. Coloured usernames will always lose
  some chroma resolution; it is the residual after §7, not the cause.
