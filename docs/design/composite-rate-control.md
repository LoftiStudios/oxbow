# Composite rate control: constant quality, not a bitrate

**Status:** measured 2026-08-29/30. The change is one argument. Three things
remain unverified before shipping (§7).

**Prerequisite reading:** [`composite-quality.md`](composite-quality.md)
establishes that the composite starves the chat column and that no single
bitrate works. This document is the answer, and it is smaller than expected.

---

## 1. The change

```diff
- -b:v <computed>M
+ -q:v 50
```

`h264_videotoolbox` targets a *quality* instead of a *bitrate*, and chooses
how many bits that costs. Per frame, automatically, with no analysis pass, no
metric, no calibration and no sections.

---

## 2. What it delivers

One `q:v 50` across four kinds of content, each a 180-second window measured
against its own pristine chat render:

| content | Mbps chosen | resulting bpp | Y |
|---|---|---|---|
| 2D RPG | 3.3 | 0.022 | 26.0 |
| talking / trailers | 3.3 | 0.023 | 26.1 |
| very heavy chat (1,253 msgs) | 7.8 | 0.053 | 27.6 |
| competitive shooter | 17.5 | 0.119 | 27.9 |

**Quality spread 1.9 dB across a 5.3x bitrate spread.** The flat 0.12 bpp that
ships today gives every one of them 17.7 Mbps and quality ranging from ~20 to
~30 dB.

Projected over six hours:

| | today (flat) | q:v 50 |
|---|---|---|
| 2D RPG | 48 GB | **9 GB** |
| talking | 48 GB | **9 GB** |
| heavy chat | 48 GB | **21 GB** |
| competitive shooter | 48 GB | 47 GB |

The shooter — the content that actually needed the bits — costs what it always
did. Everything else gets between two and five times smaller **at better and
more consistent quality**.

### It is also simply more efficient

At the *same* bitrate, constant quality beats a fixed target outright:

| window | mode | Mbps | Y |
|---|---|---|---|
| hard | constant quality q=50 | 7.8 | **25.8** |
| hard | fixed bitrate 8M | 8.5 | 19.6 |
| easy | constant quality q=50 | 4.6 | **26.2** |
| easy | fixed bitrate 5M | 5.3 | 21.5 |

**+6.3 dB and +4.7 dB for fewer bits.** A fixed target spreads bits evenly
through time; the chat column's difficulty is not evenly distributed, so an
even spread is the wrong shape.

---

## 3. The dead end this replaces, and why it is recorded

This document previously designed **per-section bitrate allocation**: split the
composite into 60-second sections, estimate each section's difficulty from
cheap content metrics, and allocate accordingly. It was designed in full and
killed by its own preconditions.

**The precondition that killed it.** The design rested on cheap metrics
(motion, spatial detail) ranking sections correctly *within* one stream. Tested
on fifteen windows across five streams, they do not:

| stream | motion+detail range | required bpp range |
|---|---|---|
| `leigh` | 22.1 → 23.6 (**7%**) | 0.061 → 0.116 (**1.9x**) |
| `heavy` | 18.4 → 47.2 (**2.6x**) | 0.073 → 0.082 (**12%**) |

Two opposite failure modes, both fatal. On one stream the need nearly doubles
while the metric barely moves; on another the metric swings 2.6x while the need
is flat. Within-stream Spearman is ~+0.5 at n=3, which is one swapped pair from
noise. An earlier two-point "validation" drawn from the same stream that now
contradicts it was a lucky draw.

**Why constant quality succeeds where the metric failed.** The encoder is not
estimating difficulty from a proxy; it is *measuring* it, by encoding. On the
same two windows whose true requirement differs 1.90x, constant quality
allocates at 1.65–1.71x — consistently, at three different quality levels —
where motion+detail saw a 7% difference.

**What the dead end cost, and what it was worth.** Two measurements from it
survive as useful facts: splitting an encode costs ~450ms per invocation
(§4.4), and seeking to a five-hour offset costs nothing (§4.3). Both would have
been needed had this gone the other way, and the second is reusable for resume.

**Why `-q:v` was not tried first.** It was, and it was dismissed —
`composite-quality.md` recorded it as "tried, not understood" after an apparent
8x cross-content divergence. That measurement came from the single-frame
harness later found to be broken (`composite-quality.md` §9). **The dismissal
should have been revisited the moment the harness was fixed, and was not.**
That delay is the most expensive mistake in this investigation.

---

## 4. The four verifications

### 4.1 Which q

Swept on two windows of one stream, targeting Y = 26 dB:

| q:v | hard window | easy window | ΔY |
|---|---|---|---|
| 40 | 23.1 @ 5.3 Mbps | 23.2 @ 3.1 Mbps | −0.1 |
| 45 | 24.5 @ 6.3 | 24.6 @ 3.7 | −0.1 |
| **50** | **25.8 @ 7.8** | **26.2 @ 4.6** | **−0.4** |
| 55 | 27.7 @ 10.3 | 28.3 @ 6.1 | −0.7 |
| 60 | 28.8 @ 12.6 | 29.7 @ 7.6 | −1.0 |

**50.** The scale is monotone and well-behaved, so this is a dial someone can
turn later with a known effect: roughly +1.3 dB and +25% bitrate per five
points.

### 4.2 Does q mean the same thing across geometries

The same source window at three geometries:

| geometry | pixel rate | Mbps chosen | resulting bpp | Y |
|---|---|---|---|---|
| 1920x1080@60 | 147.7M | 7.8 | 0.053 | 25.8 |
| 1280x720@60 | 65.7M | 4.8 | 0.072 | 26.9 |
| 1920x1080@30 | 73.9M | 4.8 | 0.065 | 25.8 |

**Within 1.1 dB**, with the bitrate adapting on its own.

This also retires `composite-quality.md` §4.2. Bits-per-pixel did not transfer
across framerate — ~0.36 bpp at 30fps against ~0.17 at 60fps for equivalent
quality — which was a real obstacle to any constant. With constant quality the
question does not arise, because bpp is an output rather than an input. Note
the resulting bpp above still varies 0.053–0.072 across geometries at equal
quality, which is exactly why no bpp constant could have worked.

### 4.3 Seek cost at a five-hour offset

Measured on a real 5-hour, 12.8 GB file, best of three, time to open and decode
one frame:

| offset | 0h | 1h | 2h | 3h | 4h | 4.9h |
|---|---|---|---|---|---|---|
| ms | 189 | 213 | 215 | 220 | 223 | **226** |

Flat. Carried over from the per-section design, where it was a precondition;
kept because resume seeks the same way.

### 4.4 Splitting an encode costs ~450ms per invocation

| | wall clock | overhead per section |
|---|---|---|
| 1 x 60s | 21.5s | — |
| 6 x 10s | 23.9s | 392ms |
| 30 x 2s | 36.3s | 494ms |

Also from the per-section design. Recorded because it bounds any future scheme
that wants to run the encoder more than once per job.

---

## 5. What changes in the code

`ArgumentBuilder`, `.composite`: `-b:v \(request.bitrateMbps)M` becomes
`-q:v 50`.

`CompositeRequest.bitrateMbps` and `CompositeGeometry.compositeBitrateMbps()`
become unused **by the composite**, but not dead:
`IntakeModel` uses the latter for the output size estimate, and the chat
render's own `-b:v 12M` is unaffected and should stay (it is an intermediate,
immediately re-encoded, and `composite-quality.md` §2.2 shows it contributes
~5% of the final error).

Whether `compositeBitrateMbps()` survives as a size *estimator* is §6.

---

## 6. The consequence: size stops being predictable

This is the real cost, and it is a product question rather than a technical
one.

Today the intake can say "about 48 GB" before the job starts, because the
bitrate is known in advance. Under constant quality the same job is somewhere
between 9 and 47 GB and **nothing knows which until the encode runs**. That is
the same fact that makes the feature good — the file is as big as the content
needs — but it removes a number the intake currently shows.

### 6.1 A probe at intake was considered and rejected

Encoding ten seconds at `q:v 50` and extrapolating would give a real number.
It is the wrong trade:

- **It costs 15–30 seconds** on good hardware and a fast connection, and more
  on a base Mac. A faithful probe needs a chat download, a video slice, a chat
  render and a composite; the chat render is the CPU-heavy part.
- **The intake downloads nothing today.** A probe makes pasting a URL a
  network-and-disk operation.
- **The settings that change the answer are on the same screen.** Quality, trim
  start and end, and whether chat is included all invalidate a probe. Either it
  re-runs on every change (unusable) or it hides behind a button (worse than no
  estimate).

The second and third points are structural, not latency that better
engineering could remove.

### 6.2 There is no free estimate either

The source's advertised bitrate arrives free with `info`, so it is the obvious
candidate. It is **anti-correlated** with the constant-quality output size:

| window | source | q50 output |
|---|---|---|
| frankie 2D | 8.56 Mbps | 3.3 Mbps |
| marzzzzy talk | 8.44 | 3.3 |
| fps shooter | 6.89 | **17.5** |
| leigh FF7 | 6.40 | 7.8 |

Spearman **−0.60** (n=6). It would confidently predict backwards, which is
worse than showing nothing. Consistent with `composite-quality.md` §4.1, where
the same field is anti-correlated with need under a fixed bitrate.

### 6.3 A duration curve: measured, and not worth building

Longer content averages its peaks away, so a duration-dependent ceiling is
tempting. Measured on two 20-minute composites at `q:v 50`, taking the maximum
rolling average at each window length:

| window | busy shooter | quiet 2D RPG |
|---|---|---|
| 1 min | 22.5 Mbps (**127%** of ceiling) | 8.4 Mbps |
| 5 min | 19.9 (112%) | 6.0 |
| 10 min | 17.3 (98%) | 5.6 |
| 20 min | 14.2 (**80%**) | 4.9 (**28%**) |

Three things fall out, and together they say no.

**Short content exceeds the ceiling rather than meeting it.** At one minute the
busy stream wants 127% of the 0.12 bpp constant. Any curve anchored at "100%
for short content" is wrong in the dangerous direction — under-promising disk.

**The duration effect is real and consistent** — 1.59x for the busy stream from
one minute to twenty, 1.70x for the quiet one — so it *would* be a reliable
correction.

**But content moves it 2.9x and duration only 1.6x.** A curve saying "80% at
twenty minutes" is right for the shooter and **three times too high** for the
2D RPG. It fixes the smaller term while the larger one is untouched, and it
cannot be fixed, because §6.2 shows nothing predicts content.

And where the correction is largest it does not matter: a clip is short *and*
is the spectacle, so it is the case that most exceeds the ceiling — but sixty
seconds at 22.5 Mbps is **169 MB**, so a 27% under-estimate is 45 MB.

### 6.4 What to do instead

**At intake, show a typical and a maximum.** Both fall out of
`compositeBitrateMbps()`, which stops steering the encode and becomes what it
is actually good at — a ceiling. It returns 0.12 bpp and the worst case
measured under `q:v 50` was 0.119, so it is an excellent one.

The typical is the median of the measured distribution, ~35% of the ceiling.
For a six-hour 1080p60 job that is "usually around 17 GB, up to 48 GB" rather
than a flat "about 48 GB". A range is more useful for deciding than a worst
case, and it is honest about the thing that is genuinely unknown.

*The typical figure rests on six windows and should be widened before it goes
on screen.*

**During the composite, replace it with the truth.** FFmpeg's `-progress`
stream already emits `total_size` every block — it is in this repo's own
`FFmpegProgressParser` fixture and simply is not extracted yet. Projecting
`total_size / fraction` gives a live estimate that converges within the first
minutes and then tracks real content drift.

That needs one more key parsed, one more field on `StepProgress`, and a
display. It lands squarely in the file `development.md` says exists to isolate
exactly this kind of parsing, and it costs nothing at runtime.

**On completion the queue shows the real size**, which needs nothing new.

Honest at every stage, no probe, and the number improves rather than going
stale.

## 7. Not verified

- **Bitrate ceiling.** Nothing in these measurements bounds what `q:v 50`
  might choose on pathological content — heavy film grain, confetti, a
  particle-heavy fighting game at 4K. A `-maxrate`/`-bufsize` guard may be
  wanted, and its interaction with VideoToolbox is untested.
- **Long-run behaviour.** Every measurement here is 180 seconds. A six-hour
  encode's rate control may drift in ways a three-minute window cannot show.
- **`-q:v` support across target machines.** Verified on this Apple Silicon Mac
  only. `docs/development.md` sets the deployment target at macOS 15, and
  VideoToolbox's constant-quality mode is not equally available on all
  hardware — on Intel Macs it is documented as unsupported for H.264. The app
  is arm64-only (`architecture.md` §7), which likely makes this moot, but
  "likely" is not a measurement.
- **Fragmented output.** All the composites above were written with the
  standard `-movflags`; the app also passes
  `+frag_keyframe+empty_moov+default_base_moof`. No reason to expect an
  interaction, and no evidence there isn't one.

---

## 8. Testing

`ArgumentBuilder` is pure and this is a one-line argv change, so the unit test
is trivial and belongs with the other argv traps: `-q:v` present, `-b:v`
absent, and `--output-args`'s own bitrate untouched.

The claim that matters cannot be tested that way. "Same quality, smaller files"
needs decoded output, and `composite-quality.md` §10 already documents the
harness. Re-run it on the four windows in §2 whenever the constant changes.

---

## 9. Next

1. **Settle §6** — the size estimate is the only user-visible regression.
2. **Bound the ceiling** (§7) before shipping, or accept an unbounded worst
   case knowingly.
3. **One long-run encode** end to end, to close §7's second bullet.

Then the change itself is a single line.
