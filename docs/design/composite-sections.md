# Per-section bitrate allocation — design

**Status:** designed 2026-08-29, not built. The blocking risk is cleared (§3.1)
and the section length is measured (§5). Two things must be settled before
implementation — §11.1 and §11.3.

**Prerequisite reading:** [`composite-quality.md`](composite-quality.md)
establishes why a single bitrate cannot work. This document assumes it.

---

## 1. What this delivers

One bitrate for a whole composite is wrong nearly everywhere, and wrong in
both directions at once. Allocating per section fixes both.

| stream | flat 0.12 bpp | per-section | file size | at the flat rate |
|---|---|---|---|---|
| FF7 Remake | 0.120 | 0.091 | **−24%** | 100% of minutes over-served |
| IRL | 0.120 | 0.075 | **−38%** | 100% of minutes over-served |
| Overwatch | 0.120 | 0.137 | +14% | **84% under-served** |

**This is a disk feature that also fixes quality.** Two of three streams get
materially smaller files at unchanged quality, because every minute of them is
currently paying for bits it cannot use. The third grows, and it is the one
that looks bad.

It costs **+3.6% wall clock** (§5).

---

## 2. Why allocation and not a better constant

From `composite-quality.md`, compressed:

- The requirement spans **7.5x** across real content at identical resolution
  and framerate — 5 to 38 Mbps at 1080p60.
- Nothing in the metadata predicts where a stream sits. The source's advertised
  bandwidth is *anti-correlated* with need.
- Cheap content metrics reach **Spearman +0.68** against required bitrate:
  enough to rank, not enough to set a rate. Two samples have indistinguishable
  metrics and 3.6x different requirements.

A flat constant must choose between wasting space on quiet content and
starving busy content, because it cannot tell them apart. **Allocating per
section never has to make that choice: a quiet stream is simply one whose
sections are all quiet.**

It also uses the part of the signal that works. Absolute classification needs a
threshold calibrated across all content, which +0.68 cannot supply. Ranking
sections *within one stream* needs no threshold — and the within-stream link
was tested directly, not assumed (§3.3).

---

## 3. Verified before designing

### 3.1 Pieces at different bitrates concatenate

The blocking risk. `-c copy` concat requires consistent codec parameters, so
if `h264_videotoolbox` shifted profile or level with bitrate the whole
approach would need a different assembly strategy.

**It does not.** Profile High, level 5.0, identical at 6, 12, 18, 25, 40 and
60 Mbps at 2280x1080@60.

Verified by assembling rather than by reading headers: joining a 6M, a 60M and
an 18M piece gives exit 0, duration exactly 3:00.05 against 3 x 60.02, a clean
full decode with no warnings, exactly **10,803 frames** against 3 x 3601, and
correct seeking into the middle piece.

### 3.2 Splitting the encode costs ~450ms per invocation

Measured on identical content at 2280x1080@60, one invocation against many:

| | wall clock | overhead per section |
|---|---|---|
| 1 x 60s | 21.5s | — |
| 6 x 10s | 23.9s | 392ms |
| 12 x 5s | 27.6s | 509ms |
| 30 x 2s | 36.3s | 494ms |

Roughly constant per invocation and independent of section length, which is
what makes §5's arithmetic simple.

### 3.3 The metric tracks need *within* a stream

Two adjacent two-minute windows of the same FF7 stream, two minutes apart:

| window | motion+detail | required bpp |
|---|---|---|
| 9600s, quiet | 11.2 | **0.059** |
| 9720s, busy | 25.9 | **0.110** |

Metric ratio 2.32x, measured need ratio **1.87x**. Direction and rough
magnitude both. This is the assumption the design rests on, and it is the one
most worth re-testing on other content.

### 3.4 Not verified

- **Seek cost at scale.** §3.2 measured seeks within a 60-second file. Section
  359 of a six-hour job seeks to hour five. `-ss` before `-i` on an indexed MP4
  should be O(log n), but "should be" is what this project's documents keep
  having to retract.
- **Frame-exactness across many boundaries** — §11.3, the most likely source of
  a subtle bug.
- **The calibration** — §11.1.

---

## 4. The shape

```
composite step launches
  |
  +-- 1. analysis pass (once, cached to disk)
  |      decode the source at quarter resolution, 4 fps
  |      -> per-section motion and detail
  |      -> per-section bitrate, clamped
  |
  +-- 2. for each section not already on disk:
  |      encode piece-N.mp4 at that section's own bitrate
  |
  +-- 3. assemble (existing step, unchanged)
         concat -c copy + the audio sidecar
```

**Sections are 60 seconds** (§5).

**Each section's rate** is `clamp(f(motion, detail))` where `f` is the
calibration and the clamp is §11.1's guardrail.

**Nothing about assembly changes.** `.assemble` already concatenates
`piece-N.mp4` with `-c copy` and maps the audio sidecar; it neither knows nor
cares that the pieces now have different bitrates.

---

## 5. Why 60-second sections

Overhead is ~450ms per invocation regardless of length (§3.2), so time cost
scales with section *count*. Adaptation lost scales the other way — longer
sections average away the variation they exist to exploit.

Both measured, on a six-hour job with a ~75-minute composite:

| section | count | time cost | minutes left under-served |
|---|---|---|---|
| **1 min** | 360 | **+3.6%** | **0%** |
| 2 min | 180 | +1.8% | 16–26% |
| 5 min | 72 | +0.7% | 26–42% |
| 10 min | 36 | +0.4% | 26–58% |

"Under-served" counts minutes whose own requirement exceeds what their block's
mean allocated them by more than 5%.

**Trading 3.6% wall clock for a 24–38% file reduction is not a close call.**
One minute is also the granularity at which the profiles in
`composite-quality.md` §8.1 actually vary, so shorter would buy little and
cost linearly more.

Twitch's own ~10s HLS segments are the wrong unit and always were: 2,160
encoder invocations for a six-hour job is 16 minutes of pure process overhead.

---

## 6. Where the analysis runs

**Inside the composite step, before the first section, cached to disk.**

Not a new `StepKind`. `docs/development.md` records what adding one costs:
one new case left the app un-buildable across four consecutive changes through
two non-exhaustive switches and eleven type errors, with `swift test` green
throughout. That is a real tax and this does not need to pay it — the analysis
has no independent progress worth showing (under 10 seconds against a
75-minute encode), no independent failure mode worth surfacing, and no reason
to be scheduled separately.

It writes `resume/<jobid>/sections.json`: the section boundaries and each
section's chosen bitrate. Written once, read on every subsequent attempt.

**That file is what makes resume correct.** A resumed attempt must re-encode
an interrupted section at *the same bitrate the first attempt chose*, or the
piece it replaces will not match its neighbours' allocation and the reasoning
behind the whole file becomes unreproducible. Recomputing from the metric
would *usually* agree, and "usually" is not good enough for something whose
output is concatenated.

---

## 7. What changes

`StepContext` gains:

- `sections: [Section]` — boundary and bitrate for each, read from
  `sections.json`

`ArgumentBuilder.composite` gains a section index and emits `-ss`, `-t` and
that section's `-b:v`. It stays pure: it is handed the plan and emits argv.

`QueueEngine` grows the loop. It already discovers existing pieces, repairs a
torn tail, and counts frames; it now also decides which *sections* those
pieces satisfy, and runs the remainder.

`CompositeGeometry` keeps `compositeBitrateMbps()` — it becomes the
**fallback** for a job whose analysis failed, and the anchor the clamp is
expressed against (§11.1). It is not dead code.

---

## 8. Resume

Sections and resume both produce `piece-N.mp4`, which is a coincidence worth
being careful about rather than a design.

**Today:** one piece per *attempt*. Piece boundaries mean "where an
interruption happened."

**With sections:** one piece per *section*. Piece boundaries mean "where a
section starts," and an interruption produces a torn piece within that.

The existing recovery sequence survives with one change of meaning. Repair the
last piece (only the last can be torn), count frames across all pieces, and
resume — but resume now means "start at the section containing that frame,"
not "seek to that frame." A torn piece is truncated to its last complete
fragment and the remainder of *that section* is re-encoded.

**This is strictly better than today.** A section is a natural restart point,
so the most work an interruption can cost is one minute of encode rather than
whatever the repair could not recover.

**The audio sidecar is written by section 0 only.** Today it is written by
whichever attempt notices it is missing, and needs a third un-seeked input on a
resumed attempt because both composited inputs carry `-ss`. Section 0 is not
seeked, so on a first run the sidecar maps from `0:a:0?` exactly as it does
now, and the third-input complication disappears. A resume that has lost the
sidecar but kept its pieces still needs it — that path is unchanged from
`resume.md` §4 and should stay unchanged.

---

## 9. Progress

`FFmpegProgressParser` reports one invocation's progress. With N sections the
step's fraction becomes

```
(completed sections + current section's fraction) / total sections
```

Sections are equal in *duration*, not in encode time — a busy minute at a high
bitrate takes longer than a quiet one — so the bar will advance unevenly. That
is honest rather than wrong, and it is a smaller lie than the current
behaviour, which `resume.md` §4 records can read 100% while the encode is
still running.

---

## 10. Failure semantics

Unchanged in shape. A section that fails fails the step; the pieces already
written stay on disk and the next attempt resumes from them. There is no
partial-success state to invent, because a job with 200 of 360 sections is
exactly what a resumable interrupted job already looks like.

One new consideration: **a section whose bitrate the analysis got badly wrong
is not a failure.** It produces a piece that looks worse than its neighbours.
Nothing detects this and nothing should try to — that is what the clamp is
for.

---

## 11. What could go wrong

### 11.1 The calibration is two points

`need ≈ 0.020 + 0.0035 x (motion + detail)` is fitted to exactly two measured
windows of one stream. Its *shape* is supported by thirteen samples at
Spearman +0.68; its *absolute levels* are not.

**The clamp is the guardrail.** Each section's rate is bounded to roughly
`0.5x .. 2x` of what `compositeBitrateMbps()` would have produced for that
geometry. Worst case, a completely wrong calibration is no worse than a factor
of two either way from what ships today — and today's flat rate is itself
wrong nearly everywhere, so the floor of the downside is not "regression from
correct."

**Widen the calibration before shipping.** The harness exists; this needs
several windows per stream across several streams, fitting need against metric
rather than assuming the two-point line.

### 11.2 Seek cost at hour five

§3.4. Measure before building the loop, not after.

### 11.3 Frame-exactness across 360 boundaries

The composite's video is concatenated; its audio is a single sidecar spanning
the whole content window. **If the video sections do not sum to exactly the
content duration, audio drifts against video** — and a drift of one frame per
section is six seconds over a six-hour job.

Sections must therefore be defined in **frames**, not seconds, with the last
section absorbing the remainder. `-t` in seconds invites rounding; a frame
count does not.

The machinery to check this already exists: `FragmentIndex` counts frames per
piece without decoding, and `resume.md` §5 already sums them. Assembly should
assert the total equals the expected frame count and fail loudly if it does
not, rather than shipping a file that desyncs an hour in.

This is the most likely source of a subtle bug in the whole design.

### 11.4 It makes some files bigger

Overwatch grows 14%. That is correct behaviour — it was starved — but a user
who has learned that their gameplay VODs are ~26 GB will see ~30 GB and may
read it as a regression. Whatever surfaces the size estimate should be able to
explain it.

---

## 12. Testing

`ArgumentBuilder` is pure and gets the same treatment as everything else in
it: given a section plan, it emits the right `-ss`, `-t` and `-b:v`. Cheap,
and it is where the argv traps live.

The analysis pass is a pure function from decoded luma to a section plan, so
it tests against a fixture without FFmpeg.

The clamp is a pure function and should be tested at both rails.

`QueueEngine`'s section loop needs the same treatment `resume.md` §11 gives
recovery: a fake process that writes plausible pieces, then assertions about
which sections get re-run.

**End to end, against decoded output, per `twitch-metadata.md` §7.** The claim
this design makes is that files get smaller at unchanged quality. That is
exactly the kind of claim an exit code cannot support, and the measurement
harness in `composite-quality.md` §10 already exists to check it.

---

## 13. Not in scope

- **A user-facing quality tier.** If this lands, the useful control becomes a
  total-size budget, which is a question people can answer. Not this document.
- **Per-section allocation for the chat render.** The render is not the
  bottleneck and its bitrate is already generous.
- **Anything about chroma subsampling.** `h264_videotoolbox` is 4:2:0-only and
  the delivered file has to play everywhere.
- **Replacing the flat constant.** `compositeBitrateMbps()` stays as the
  fallback and the clamp's anchor.
