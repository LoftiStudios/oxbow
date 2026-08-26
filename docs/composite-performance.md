# Composite performance: where the time goes, and why none of it comes back

**Status:** resolved. Spike run 2026-08-26 against the real bundled binaries.

`docs/design/compositing.md` §10 named piping the chat render's raw frames into
the composite as "the most valuable unbuilt thing here," worth **~1.7x wall
clock**, and recorded an AVFoundation composition as the plausible alternative.
This document measures both, and four further approaches the spike generated
along the way.

**None of the six survived.** The composite step is bound by the throughput of
Apple's hardware H.264 encoder, at roughly **800 Mpx/s of output pixels**, and a
single FFmpeg process already extracts 94% of that. Every approach that does not
reduce the number of output pixels saves nothing, because everything else is
already hidden behind the encoder.

Read `docs/design/compositing.md` first; this document assumes its geometry
(§4), its argv (§7), and its measured timings (§9).

---

## 1. The model, in one line

```
composite wall clock  =  max( decode + filter,  output_pixels_per_second × duration ÷ ~800 Mpx/s )
```

The right-hand term dominates every real job. The left-hand term — decoding two
H.264 streams and stacking them — is real work, roughly 60% as much, and it runs
entirely in the encoder's shadow. **Optimising anything on the left is
unobservable.** That single fact kills the two approaches below that attack
decode; the encoder's own fixed throughput kills three more; the sixth dies for
a reason that has nothing to do with speed.

## 2. Setup

Reproducible, because the conclusion depends on the hardware:

| | |
|---|---|
| Machine | MacBookPro18,4 — M1 Max, 8 performance + 2 efficiency cores, 64 GB |
| FFmpeg | the bundled LGPL build, 8.1.2, `build/ffmpeg/ffmpeg` |
| Helper | `TwitchDownloaderCLI 1.56.5+d4122d80214b08b3c7078003aae43088e601a435` |
| Source | `twitch.tv/videos/1480816483` — 547s (9:07), source rendition **1824x1026 @ 30**, `BANDWIDTH=6356129`, decoding at 5970 kb/s |
| Derived geometry | chat **342x1026 @ 30**, output **2166x1026**, composite bitrate **10 Mbps**, font size 15 |
| Chat | 72,697-byte JSON; render took 77.5s and produced 145.7 MB (2.13 Mbps, well under the 12 Mbps ceiling) |

The 10 Mbps is `CompositeGeometry.compositeBitrateMbps` doing its job: the
pixel-ratio-and-headroom formula asks for 11.3 Mbps and `maxBitsPerPixel` caps it
at 10.0.

A 30 fps source was deliberate — it halves the frame count against
`compositing.md` §9's 1080p60 run, so the two measurements probe the same
ceiling from different directions and can be cross-checked against each
other (§5).

**Baseline, the app's exact argv:** 48.4s for 547s of content — **11.3x
realtime**. Eight runs between 48.11s and 48.88s, plus one cold-cache 52.02s.

## 3. Where the 48 seconds go

| Probe | Time |
|---|---|
| Baseline composite | **48.4s** |
| Video decode alone (`-f null -`) | 23.6s |
| Chat decode alone | 12.6s |
| Decode both + `setpts`/`fps`/`hstack`, no encode | 29.3s |
| Output scaled to ¼ the pixels (1082x512) | 30.5s |
| Output scaled to 1/16 the pixels (542x256) | 28.2s |

Read naively, this says decode+filter is 29s and encode is the remaining 19s.
**That reading is wrong**, and the scale rows are what disprove it: shrinking the
*output* to a sixteenth of its pixels — which cannot make decoding any faster —
drops the total to 28.2s and stops there. So 28–29s is a decode floor that the
encoder is sitting on top of, not a serial prefix. At full size the encoder needs
~46s and the decode disappears underneath it.

CPU time corroborates it: `user 137.30s, sys 11.29s` over 48.88s wall is about
**3.0 cores of 10 busy**. The job is not CPU-starved. It is waiting on one piece
of fixed-function silicon.

## 4. Six approaches, and the measurement that killed each

### 4.1 Piping raw frames instead of an intermediate H.264 file — 0s

`compositing.md` §10's proposal, simulated exactly: a producer process emits
raw frames into a pipe and the composite reads them as its second input, which
is what a FIFO from the chat renderer would deliver.

| | |
|---|---|
| Baseline (chat as an H.264 file) | 48.4s |
| Chat as raw `yuv420p` over a pipe | **48.4s** |
| Chat as raw `bgra` over a pipe (what the CLI actually pipes) | **48.5s** |

Zero, in both pixel formats. The 12.6s of chat decode it removes was never on
the critical path.

**Its 1.7x was never arithmetically available**, independently of this
measurement. `compositing.md` §6's realised timeline is
`chat + max(video 9, render 14) + composite 74` ≈ 88 min for a six-hour job.
The FIFO changes that to
`chat + video 9 + composite 74` ≈ 83 min: it removes the render from the
timeline, but the render was already hidden behind the video download. **1.06x,
about five minutes** — and only if the composite itself were unchanged, which it
is.

What the FIFO *does* buy is real but is not speed: **10.2 GB off the 55–120 GB
disk peak**, and a chat column encoded once from pristine frames rather than
twice. Both matter. Neither is worth hard-coupling two processes, FIFO cleanup on
cancellation, and breaking `Scheduler`'s one-compute-step-per-class rule.

### 4.2 Hardware-accelerated decode — 0s, and slower in isolation

Never considered in `compositing.md` §10, and the bundled LGPL build already
supports it — no rebuild needed. `ffmpeg -hwaccels` reports `videotoolbox`,
`hwdownload` and
`hwupload` are compiled in, and it genuinely engages
(`Reinit context to 1824x1040, pix_fmt: videotoolbox_vld`).

| Probe | Time |
|---|---|
| Video decode alone, software | 23.6s |
| Video decode alone, `-hwaccel videotoolbox` | **79.6s** — 3.4x *slower* |
| Composite, `-hwaccel` on the video input | 48.9s |
| Composite, `-hwaccel` on both inputs | 52.3s |

Downloading every frame from an IOSurface back into system memory — which
`hstack` requires, since FFmpeg on macOS has no VideoToolbox filter family —
costs more than the decode engine saves. And it would not have mattered either
way, because decode is not the constraint.

### 4.3 Splitting the job across parallel processes — 0s

Segment the timeline into N ranges, composite each concurrently, concatenate with
a stream copy.

| | Encode | Concat | Total |
|---|---|---|---|
| N=2 | 46.28s | 1.08s | **47.36s** |
| N=4 | 46.59s | 1.32s | **47.91s** |
| N=6 | 47.33s | 1.40s | **48.74s** |

N processes each doing 1/N of the frames take **exactly as long as one process
doing all of them**. That is the signature of a serialised shared resource, and
it is the single most diagnostic result in this document — §6 explains why it
happens.

Note the concat: **1.1–1.4 seconds**, and segmenting costs nothing. That is
useful later (§7) even though it buys no speed here.

### 4.4 Encoder tuning — 0s, or worse

| Setting | Time |
|---|---|
| Default | 48.11s |
| `-prio_speed 1` | 48.12s |
| `-coder cavlc` | 47.92s |
| `-max_ref_frames 1` | 48.33s |
| `-power_efficient 0` | 48.73s |
| `-profile:v main` | 48.33s |
| `-pix_fmt nv12` / omitted / `yuv420p` | 48.46 / 48.50 / 48.88s |
| `-filter_threads 1` | 49.23s |
| `-b:v 2M` instead of `10M` | 47.81s |
| `hevc_videotoolbox` | 49.94s |
| **`-realtime 1`** | **178.09s** |

No knob exists. `-b:v 2M` confirms `compositing.md` §4's "bitrate is free in
wall-clock time" from the other direction, and `hevc_videotoolbox` confirms its
§10 claim of essentially equal speed. **Never pass `-realtime`** — its
documented meaning is "encode in
real time *if not faster*," and it throttles a 48s job to 178s.

### 4.5 Two video tracks in one container — 60x faster, and unplayable

The most promising idea the spike generated, and the one worth documenting most
carefully so nobody re-derives it.

A QuickTime/ISO-BMFF track header carries a full 3x3 transform matrix. A movie
can therefore hold the VOD and the chat render as two *stream-copied* video
tracks laid out side by side — no re-encode of anything, ever:

```bash
ffmpeg -i video.mp4 -i chatrender.mp4 -map 0:v -map 1:v -map 0:a -c copy out.mov
# then patch track 2's tkhd matrix: tx = 1824 << 16
```

**The mux takes 0.80 seconds** against the composite's 48.4 — a 60x speedup —
and the result is strictly *higher* quality than the app ships today: the video
half is bit-identical to the source instead of a second lossy generation, and the
chat column is never re-encoded at all. `compositeBitrateMbps` and its whole PSNR
justification would become dead code.

AVFoundation reads the layout exactly as intended:

| Check | Result |
|---|---|
| `AVVideoComposition.videoComposition(withPropertiesOf:)` | `renderSize` **2166x1026**, two layer instructions on trackIDs [1, 2] — plus a third for the 10 ms tail where the chat render has ended |
| `AVAssetImageGenerator` given that composition | a correct 2166x1026 side-by-side frame |

**But nothing asks it to.** Playback never builds that composition:

| Check | Result |
|---|---|
| `AVPlayerItem.videoComposition` after load | **nil** |
| `AVPlayerItem.presentationSize` | **342x1026** |
| `AVPlayerItemVideoOutput` pixel buffers | **342x1026** |
| `qlmanage -t` (Finder, Quick Look) | **342x1026** |
| VLC 3.x | opens the two tracks in **two separate windows**, played in sync |

QuickTime honoured track matrices at playback; AVFoundation replaced QuickTime
and honours them only through an explicit `AVVideoComposition`. So QuickTime
Player, Quick Look, Photos, and every AVKit app show a 342-pixel column of chat
and no game — it does not even degrade to video-only. Clearing the chat track's
`alternate_group` (FFmpeg assigns 0 and 1, so they were never alternates) and
setting `layer = -1` changed nothing.

Oxbow could render the file correctly in its own preview. That is worth nothing,
because the point of the deliverable is that it plays elsewhere.

**Do not revisit this without first re-checking `AVPlayerItem.presentationSize`
on a two-track movie.** If some future macOS composites by default, the idea
becomes a 60x win overnight; until then it is dead, and the test is one line.

### 4.6 A faster encoder path — 7%, and AVFoundation is slower

The last hypothesis standing: that ~800 Mpx/s is FFmpeg's VideoToolbox wrapper
rather than the silicon. The M1 Max has two documented video encode engines, and
every measurement so far had gone through the same `h264_videotoolbox` code path,
so §4.3's result could not distinguish a hardware limit from a shared software
one.

Benchmarked directly: 300 real 2166x1026 NV12 frames pre-decoded into RAM, then
9,000 frames pushed through `AVAssetWriter` with only the encode timed.

| Path | Throughput |
|---|---|
| `AVAssetWriter`, 1 session | 276.5 / 274.7 fps — **~612 Mpx/s** |
| `AVAssetWriter`, 2 concurrent sessions | 361.8 / 361.1 fps — **~804 Mpx/s** |
| FFmpeg composite, 1 process | 339 fps — **≥755 Mpx/s** |
| FFmpeg composite, 2 processes (§4.3) | no gain |

Both repeats of every configuration landed within 1%. Three and four concurrent
sessions were noisier and never exceeded two.

Two conclusions. **AVFoundation's own writer is 19% slower than FFmpeg** at one
session, so `compositing.md` §10's instinct that an AVFoundation composition
would be faster was backwards in every respect. And the second encode engine is
real but weak: two sessions give **1.31x, not 2x**.

That also explains §4.3. Parallelism did not fail; **a single FFmpeg process is
already at 94% of the ceiling**, so there was nothing to parallelise into. The
headroom between what FFmpeg extracts and what the silicon can do is
804 ÷ 755 = **7%** — about five minutes on a six-hour job.

*Control:* the `AVAssetWriter` runs happened under an elevated load average
(~9 on 10 cores, from unrelated work). The FFmpeg baseline was re-measured under
that same load at 48.31s and 48.27s, against 48.4s earlier in the day, so the
comparison is not distorted.

## 5. The ceiling, and predicting any job from it

The composite's output pixel rate is 2166 × 1026 × 30 = **66.7 Mpx/s**. FFmpeg
delivered 547s of it in 48.3s, so its encode throughput is at least
`16410 frames × 2.2223 Mpx ÷ 48.3s` = **755 Mpx/s**.

Cross-check against `compositing.md` §9's independent run — different source,
different resolution, different framerate, measured weeks apart: 2280 × 1080 × 60
= 147.7 Mpx/s, six hours in 74 minutes, giving **719 Mpx/s**. Two measurements
agreeing within 10%, and an `AVAssetWriter` ceiling of 804 Mpx/s above both.

So, for any job:

```
composite minutes  ≈  output_width × output_height × fps × duration_seconds ÷ 750e6 ÷ 60
```

Applied to the six-hour 1080p60 case that `compositing.md` §9 measured at
74 minutes, this predicts 71. Use it to sanity-check any future proposal
*before* building it — that is the step this spike existed to supply.

## 6. Why the encoder cannot be worked around

Three properties, each measured rather than assumed:

- **Cost is per output pixel, not per bit.** `-b:v 2M` and `-b:v 10M` differ by
  0.6% in time (§4.4), and `compositing.md` §4's own PSNR work found the same. Content complexity
  does not change it either.
- **Cost is per output pixel, not per input pixel.** Scaling the output down
  while decoding the same inputs cuts the time to the decode floor (§3).
- **The resource is global.** N processes do not beat one (§4.3), and two
  `AVAssetWriter` sessions reach only 1.31x (§4.6).

And the output pixels are not negotiable within one video track. **H.264
addresses macroblocks in raster order across the whole frame**, so widening
1824 → 2166 invalidates every macroblock address, every intra-prediction
neighbour at the seam, every motion-vector predictor, and the CABAC context.
There is no way to splice the source's existing bitstream into a wider frame.
HEVC tiles would permit exactly that stitch; Twitch does not ship HEVC, and
re-encoding to get there costs what it was meant to save.

`architecture.md` §7 asserted "spatial composition changes every pixel, so a full
re-encode is unavoidable." That is now proven rather than assumed, and the reason
is format-level, not a limitation of our approach.

## 7. What is actually left

**Only output pixel rate moves wall clock**, and every way of reducing it
discards something. On the six-hour 1080p60 job (~88 min end to end):

| Lever | Result | Cost |
|---|---|---|
| Composite 60 fps sources at 30 | 88 → **51 min (1.7x)** | half the video half's frames |
| 720p composite from a 1080p60 source | 88 → **47 min** | resolution |
| Narrow or delete the chat column | at most **−16%** | it is the feature; the column is 342 of 2166 columns |

The 1.7x `compositing.md` §10 attached to the FIFO is real — it just belongs to
the framerate lever. That document's §4 already halves the *chat* render's
framerate on exactly the reasoning that would justify it. It is a deliverable
change, not an optimisation, and should be decided as one.

**The one non-destructive option is to stop making the user wait for the whole
thing.** §4.3 measured segmenting as free (47.4s against 48.4s, concat included),
and each finished segment is an ordinary MP4 that can be concatenated on demand
in about a second. That does not make the composite faster — nothing does — but
it changes time-to-first-watchable-frame from 88 minutes to roughly 11, in one
file under the final name, growing while it is watched. It also buys retry
granularity (a failure at minute 70 currently costs 74 minutes of re-encoding)
and a much lower disk peak, since each segment's inputs can be discarded once
composited.

`videodownload` and `chatrender` both accept `-b`/`-e`, and `ArgumentBuilder`
already has the `trim(start:end:)` helper wired, so the pieces exist. Two things
would have to be established first: whether the CLI's trim is **frame-exact**, or
segment boundaries drift; and how to handle the **AAC seam**, since concatenating
per-segment audio risks priming gaps. The spike sidestepped the second by
compositing segments video-only and muxing the full audio once at the end with
`-c copy` — which works, but presumes a complete download and so gives up most of
the pipelining.

None of that is designed. It restructures one composite step into N plus a
concat, which `compositing.md` §6's DAG and its §7 failure handling both have
opinions about.

## 8. Reproducing this

Everything above came from the bundled binaries and one real VOD. To re-run on
different silicon — the conclusion is hardware-specific and an M4 media engine
will not have the same ceiling:

```bash
# inputs
build/helper/TwitchDownloaderCLI videodownload --banner=false --collision Overwrite \
  --id 1480816483 -o video.mp4 --temp-path tmp --ffmpeg-path build/ffmpeg/ffmpeg
build/helper/TwitchDownloaderCLI chatdownload --banner=false --collision Overwrite \
  --id 1480816483 -o chat.json --temp-path tmp

# the chat column, at the geometry CompositeGeometry derives for this source
build/helper/TwitchDownloaderCLI chatrender --banner=false --collision Overwrite \
  -i chat.json -o chatrender.mp4 --temp-path tmp --ffmpeg-path build/ffmpeg/ffmpeg \
  -w 342 -h 1026 --framerate 30 --font-size 15 -f "Inter Embedded" \
  --background-color "#111111" --alt-background-color "#191919" \
  --message-color "#ffffff" --outline-size 4 \
  '--output-args=-c:v h264_videotoolbox -b:v 12M -pix_fmt yuv420p "{save_path}"'

# the two numbers that matter
build/ffmpeg/ffmpeg -i video.mp4 -i chatrender.mp4 \
  -filter_complex "[0:v]setpts=PTS-STARTPTS[v];[1:v]setpts=PTS-STARTPTS,fps=30[c];[v][c]hstack=inputs=2[out]" \
  -map '[out]' -an -c:v h264_videotoolbox -b:v 10M -pix_fmt yuv420p out.mp4   # total
build/ffmpeg/ffmpeg -i video.mp4 -i chatrender.mp4 -filter_complex "…same…" \
  -map '[out]' -an -f null -                                                   # decode floor
```

If the two are close, the machine is decode-bound and this document's conclusions
do not apply to it. If the first is much larger, divide output pixels per second
by the elapsed ratio to get that machine's encoder ceiling, and use §5.
