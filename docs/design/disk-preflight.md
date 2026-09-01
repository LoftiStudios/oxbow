# Disk-space preflight

Nothing in Oxbow predicts how much room a job needs before committing to it.
[`compositing.md`](compositing.md) §10 has called this "the most valuable
unbuilt thing, and the one with a live failure mode" since the composite
shipped. This is that thing.

The failure it prevents: a six-hour 1080p60 composite runs for about
eighty-eight minutes and today discovers there is no room for it by running
out. The user gets a failed job, a part-written file, and no explanation they
can act on.

`compositing.md` §10 puts that job's peak at 55–120 GB. This document's own
estimator (§3) puts it nearer **49 GB** on a single volume, and the difference
is not a disagreement: that range was written while the composite was encoded
at a computed bitrate, and 0.3.0's move to constant quality cut the output term
by roughly the factor the changelog describes. The older figure should be read
as the pre-0.3.0 number it is.

---

## 1. What this delivers

**One check.** At intake, a warning under the destination when the estimate
exceeds what the volume has. It never blocks — `Add` stays `Add`.

It does not probe the network and does not run FFmpeg.

**A second check, before the composite step, was designed and then dropped.**
§6 keeps that design and the reason, because the reason is a fact about the
code rather than a change of mind.

**What it does not deliver** is a guarantee. §9 says so at length, because the
term that dominates the sum is the one this project has already established
cannot be predicted.

---

## 2. Why it warns rather than blocks

**At intake there is a person.** They know things the estimator does not —
that a 200 GB Time Machine snapshot is about to be thinned, that the external
drive is about to be plugged in, that they intend to cancel the job at 40%
having got what they wanted. Refusing them is refusing on worse information
than they have.

This also follows the precedent set for the destination-collision warning in
0.3.0, which is the closest existing thing: *nothing is blocked — the click is
named for what it does*. A warning that blocks is a different kind of object
from one that informs, and having two kinds in one panel would teach the user
that neither can be trusted.

That is the whole rule. There is no second, stricter mode — see §6.

---

## 3. The estimate

Four terms. Three are solid; one is the whole problem.

| term | derivation | confidence |
|---|---|---|
| source download | `StreamQuality.estimatedBytes(over:)` — exists today | **high** |
| chat JSON | ignored | n/a |
| chat render intermediate | 3.85 Mbps x duration | good |
| composite output | 0.038 bpp x composite pixel rate x duration | **weak** |

**The source download** is `bitsPerSecond x duration`, already written and
already used by the quality picker. Twitch transcodes to a flat target and
[`composite-quality.md`](composite-quality.md) §4.1 measured delivered bitrate
at 95–97% of advertised on every sample, so this term is accurate to a few
percent. Note the irony recorded there: `BANDWIDTH` is an excellent predictor
of the download it describes and a uselessly misleading one for anything else.

**The chat JSON is ignored deliberately.** A six-hour chat is tens to low
hundreds of megabytes against a sum measured in tens of gigabytes. Carrying a
term that never changes an answer is a term that can only be wrong.

**The chat render intermediate** is 3.85 Mbps, the figure `compositing.md` §10
records from practice — text on a flat background compresses far below its
12 Mbps ceiling. Applies only when the job renders chat.

It is treated as **flat across geometries**, which §3.1 spends a page arguing
is the wrong shape for the composite term. The inconsistency is deliberate and
narrow: 3.85 Mbps is a single practical figure at 1080p, scaling it would mean
inventing a bpp for the chat column that nobody has measured, and the term is
the smallest of the three. Treating it as flat over-states smaller geometries,
which errs toward warning. If it is ever measured at a second geometry, this is
the paragraph to delete.

### 3.1 The composite term, and why it scales by bits-per-pixel

The composite is encoded at constant quality (`-q:v 50`), so its size is
chosen by the encoder rather than requested by us. Two things have to be
picked: a level, and a way to scale that level across geometries.

**The scaling is bits-per-pixel**, over the *composite output* frame:

```
compositePixelRate = geometry.outputWidth x geometry.videoHeight x geometry.videoFramerate
compositeBits      = 0.038 x compositePixelRate x durationSeconds
```

This needs justifying, because
[`composite-rate-control.md`](composite-rate-control.md) §4.2 says in as many
words that **no bpp constant could have worked**. That verdict stands, and it
is not contradicted here, because it is answering a different question. There,
bpp was proposed as an *encoder input* that had to land within about a
decibel of a quality target; the measured 0.053–0.072 spread across geometries
made it unusable for that. Here it is a *size estimator* whose content term
already spans 5.3x, and the only question is which of the two available
scalings tracks geometry less badly.

Its own table answers that. One content window at three geometries:

| geometry | composite pixel rate | Mbps chosen | resulting bpp |
|---|---|---|---|
| 1920x1080@60 | 147.7M | 7.8 | 0.053 |
| 1280x720@60 | 65.7M | 4.8 | 0.072 |
| 1920x1080@30 | 73.9M | 4.8 | 0.065 |

Fit each candidate to that content and compare the error:

| geometry | flat Mbps | bpp x pixel rate |
|---|---|---|
| 1920x1080@60 | 0% *(calibration point)* | +20% |
| 1280x720@60 | **+63%** | −13% |
| 1920x1080@30 | **+63%** | −3% |

A flat megabit figure over-states every smaller geometry by nearly two
thirds, because it ignores that half the pixels cost roughly two thirds the
bits. Bits-per-pixel is wrong by at most a fifth in either direction. Neither
is good; one is usable.

Those pixel rates are the composite's, not the source's — 1920 + 360 = 2280
wide at 1080 by 60 gives 147.7M, which is what that table's first column
holds. `CompositeGeometry` already computes every one of those numbers.

### 3.2 What 0.038 is, and what it is worth

The median of the four samples in `composite-rate-control.md` §2, the only
measurements of what `-q:v 50` actually produces:

| content | Mbps chosen | resulting bpp |
|---|---|---|
| 2D RPG | 3.3 | 0.022 |
| talking / trailers | 3.3 | 0.023 |
| very heavy chat | 7.8 | 0.053 |
| competitive shooter | 17.5 | 0.119 |

Median bpp = 0.038. Over six hours at 1080p60 that is about **15 GB**, which
sits sensibly between the 9 GB the 0.3.0 changelog quotes for a quiet 2D
stream and the busy end.

**This constant is n=4 over a 5.3x spread, and should be read as an order of
magnitude rather than a number.** It will under-state a competitive shooter by
roughly 3x and over-state a 2D RPG by roughly 1.7x. That is the accepted cost
of the decision in §9; it is not a defect to be fixed by tuning the constant,
because no single constant is available that would fix it.

**A margin was considered and rejected.** Multiplying the estimate by a safety
factor would be inventing a number to compensate for a number we already know
to be soft, and would move the warning's threshold without improving what it
knows. The check fires when the estimate exceeds available space, and on
nothing else.

---

## 4. Two volumes

`Workspace` lives in the app's cache directory on the system volume. The
destination is chosen by the user and may be an external drive. The peak is
per-volume, not global, and `QueueEngine.move` uses `moveItem` — which is a
rename within a volume and a copy-then-delete across one.

**Same volume**, everything stacks and the delivery is free:

```
need = source + intermediate + composite
```

**Different volumes**, the workspace carries the transient set and the
destination carries only what is delivered:

```
workspace volume:   source + intermediate + composite
destination volume: composite
```

For a plain download the same model holds with the intermediate and composite
terms at zero.

**Free space is read with `volumeAvailableCapacityForImportantUsage`**, not
`volumeAvailableCapacity`. The former counts space the system will purge to
satisfy an important write, which is what actually happens, and on a Mac with
a large local snapshot store the two differ by tens of gigabytes. Using the
raw figure would produce warnings on machines with plenty of usable room.

---

## 5. Check one: the intake

A computed property on `IntakeModel`, beside `destinationCollision` and built
the same way — the free-space read is injected so the rule is testable without
a real volume, exactly as the collision rule's file probe is.

It recomputes as the destination, quality, trim range and chat toggle change,
since all four move the answer.

Presented under the destination field, in the same position and tone as the
collision warning:

```
Needs about 49 GB · 45 GB free on Macintosh HD
720p would need about 27 GB
```

Both figures are this estimator's, for a six-hour job: 23 GB of source, 10 GB
of intermediate and 15 GB of composite at 1080p60, against 9 + 10 + 7 at
720p60.

**The remedy line is the point.** "Insufficient disk space" tells the user
something they will discover anyway. Naming the next rendition down, with its
own estimate, turns the warning into one click of work. It is shown only when
a lower rendition would actually fit — offering a remedy that also does not
fit is worse than offering none.

`Add` is unchanged and unblocked.

---

## 6. Check two: designed, and not built

An earlier version of this document specified a second check in `QueueEngine`,
run as the `.composite` step was admitted: re-read free space, re-estimate the
remaining output, and fail the step in about a second rather than seventy
minutes. The argument for it still holds — the user clicked `Add` hours ago and
is not at the keyboard, so the choice there is not refuse-or-permit but
fail-early or fail-late.

**It was dropped during implementation, because the composite step has nothing
to estimate from.**

`CompositeRequest` carries `framerate`, `duration` and `destination` and
deliberately **no geometry** — `hstack` derives every dimension from its inputs
and refuses unequal heights outright, which is the property `compositing.md` §5
wanted. So at composite time there is no resolution, and without one there is no
pixel rate and no estimate. Nothing else in the job supplies it either:
`VideoRequest.quality` is a picker *name* like `1080p60`, not a `StreamQuality`
with a resolution on it.

Two ways to close that were considered and both rejected as too much churn for
the value:

- **Carry the estimate itself** on `CompositeRequest` as an optional
  `Int64`, computed at intake where the geometry exists. Cheapest, and keeps
  the no-geometry decision intact, but it adds a persisted field and a decode
  path for jobs queued before it existed.
- **Carry the geometry**, and re-derive in the engine. Directly contradicts the
  documented reason that type has none, and that reasoning is still sound.

**What this costs**, stated so it is a decision rather than a gap: space that
disappears between `Add` and the composite running is not caught. That job dies
on `ENOSPC` at whatever percent it reaches, exactly as it does today. The intake
check covers the common case — the disk was already too full when the job was
created — and does not cover the disk filling underneath a queued job.

If this is ever revisited, the estimate-on-the-request option is the one to
take.

---

## 7. What changes

| unit | change |
|---|---|
| `SpaceEstimate` (new) | the estimator: pure, no I/O |
| `VolumeSpace` (new) | the injected free-space read |
| `CompositeGeometry` | `+ pixelRate` — the one number §3.1 needs |
| `IntakeModel` | `+ spaceWarning`, computed like `destinationCollision` |
| `IntakeWindow` | the warning line and its remedy |
| `QueueEngine`, `Scheduler`, `StepFailure` | **none** — see §6 |

**Nothing in the queue changes at all.** No new step, no new failure case, no
scheduling rule — the whole of this lands in front of the job being created.
That is a smaller footprint than the first draft of this document assumed, and
§6 is why.

Both suites are still required, because `CompositeGeometry` is public and
`SpaceEstimate` is new: a change to a public OxbowKit type can leave
`swift test` green while the app target stops compiling.

---

## 8. Testing

**The estimator is a pure function** and gets a table driven from the real
sample geometries in §3.1 — a case per row, asserting the predicted bytes
against the measured Mbps within a stated tolerance. If someone later changes
0.038, the table is where they will see what it costs.

**The volume read is injected**, so both checks are testable without filling a
disk: same-volume and cross-volume arrangements, a destination on a volume
that does not exist, and the boundary where the estimate exactly equals free
space.

**The intake rule** is tested the way the collision rule is — through
`IntakeModel`, with the probe substituted.

**The engine check** gets an end-to-end test asserting that a composite whose
estimate exceeds a stubbed free-space figure fails before the helper is ever
launched, which the existing `FakeHelper` can observe directly: it records
every `Launch` it is handed, so "never launched" is an assertion rather than
an inference.

---

## 9. Deferred, deliberately: the live projection

`composite-rate-control.md` §6.1 recommends a third check — comparing the
composite's live projected size, derived from FFmpeg's own `total_size`,
against remaining free space while it encodes — and argues for it on safety
grounds:

> Without it, a job heading for 300 GB looks exactly like a job heading for 30
> until the disk fills.

**That recommendation is not being implemented here, and the reasoning is
sound.** It is deferred to keep this change to one reviewable piece, in the
same spirit as the retention ceiling deferred in `resume.md` §8.

**What that leaves uncovered, stated plainly.** Two things, and together they
are most of the tail:

1. **The estimate is a median.** A VOD landing at the busy end of the 5.3x
   spread passes the check and still runs out of room.
2. **Only the intake is checked** (§6). A disk that fills underneath an already
   queued job is not noticed until the composite hits `ENOSPC`.

This design makes running out rarer. It does not make it impossible, and
anyone reading a passing preflight as a guarantee is reading it wrong.

The live projection is the thing that would close both, because it measures
rather than predicts — and the projection is already computed for the 0.3.0
progress UI, so what remains is a comparison, not machinery. It should be the
next change here.

**Why that is an acceptable place to stop.** Running out of disk is an edge
case, and the estimator is wrong in both directions on the tail of it. The
alternative designs that close the gap all cost more machinery than the case
justifies — a probe at intake that re-runs on every keystroke, a per-content
model with no data to fit it, a third check plumbed through the encode. A
warning that is roughly right, cheap, and honest about being roughly right is
worth more here than a precise one that few people ever see. Be wrong before
being elaborate.

Also out of scope:

- Any ceiling or quota on what a job may consume.
- Checking space for the download-only steps mid-flight. A download that runs
  out of room fails in minutes, and the intake check already covers it.
- Predicting the chat JSON's size (§3).

---

## 10. Open questions

- **The remedy line when no lower rendition fits.** Currently: show the
  shortfall alone. The alternative — naming a shorter trim — is arithmetic the
  user can do and a suggestion they may find presumptuous.
- **Clips.** The estimator's terms all hold, but a clip's duration is short
  enough that the check will essentially never fire. Whether to skip the read
  entirely below some duration is a performance question nobody has measured,
  and it is cheap to leave in.
