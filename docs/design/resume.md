# Resuming an interrupted composite — design

**Status:** approved 2026-08-26. Not yet implemented.

Prerequisites: `docs/design/fragmented-output.md` (the container change this
depends on entirely), `docs/design/compositing.md` (the step being resumed), and
`docs/composite-performance.md` (why the composite is ~74 minutes and will stay
that way).

---

## 1. What this delivers

**Retry stops restarting and starts continuing.** No new UI and no new user
concept: an interrupted composite comes back as `.failed(.interrupted)` exactly
as it does today, and Retry picks it up where it stopped rather than at zero.

It covers interruption **across launches** — app quit, crash, closing the
laptop, reboot — as well as in-session failures. Those are the likeliest ways a
74-minute unattended encode dies, and today every one of them costs the whole
job.

On a six-hour stream whose composite died at 90%:

| | Retained between launches | Recovery |
|---|---|---|
| Today | nothing | **~88 min** — the entire job again |
| With this | ~26 GB | ~16 min re-fetch + ~7 min tail = **~23 min** |

This is possible **only** because the composite now writes a fragmented MP4.
`fragmented-output.md` §1 is the argument: a conventional MP4 writes its index
at the very end, so a composite killed at 90% leaves 26 GB of undecodable
bytes and there is nothing to resume from.

## 2. Verified before designing

Spiked 2026-08-26 against the real 547s VOD (`twitch.tv/videos/1480816483`),
and against a synthetic source as a cross-check. The partial file was truncated
**mid-fragment** to simulate a crash or power loss — not a clean SIGTERM, which
lets FFmpeg finalise and is the easy case.

| Question | Answer |
|---|---|
| Can a torn file be repaired? | **Yes.** Cutting after the last complete `mdat` recovered a clean decodable file every time. A trailing `moof` with no `mdat` is useless, so the cut goes after the `mdat`, not after the last box that fits. |
| Is the surviving prefix trustworthy? | **Yes.** Piece 0's frames read **MAD 0.000** against a straight-through encode of the same range — identical, not merely similar. |
| Are frames lost or duplicated at the join? | **No.** Real VOD: 2232 + 3769 = **6001**, matching the reference's 6001. Synthetic: 2796 + 3205 = **6001**. |
| Does the tail start at the right frame? | **Yes.** Piece 1's first frame against the raw source: `74.400` → **MAD 1.839** (compression noise), against 10.5–13.3 at every neighbouring frame time. |
| Is it placed correctly in the joined file? | **Yes.** The concatenated file at t=74.4 scores identically to piece 1's own first frame. |
| Does audio survive the seam? | **Yes**, because pieces are composited video-only and the audio is mapped once from the intact source at delivery. No AAC priming gap to reconcile. |

### The resume point is a timestamp, and that is why it is robust

`-ss (total frames ÷ framerate)` on the source is correct **even though the
output has a different frame count than the source.** Measured: the source
holds 5998 frames across 200s where the composite emits 6001, because CFR
conversion fills small gaps by duplication.

That does not matter, and the reason is worth writing down because it is not
obvious. The composite's output is CFR at `framerate`, so output frame N sits
at output time `N ÷ framerate`. The filter graph applies `setpts=PTS-STARTPTS`
and no rate change to the video, so **output time is source time**. Seeking the
source to `N ÷ framerate` therefore lands on the frame that becomes output
frame N, regardless of how many frames CFR fill inserted along the way.

Resume must seek by **time**, never by frame index. See §2.1.

### 2.1 The measurement trap, recorded so it is not repeated

Most of this spike was spent chasing a defect that did not exist. The cause was
using `trim=start_frame=N` as the ground truth for "output frame N".

**On Twitch sources, frame-index counting and timestamp seeking do not agree:**

| Comparison, on the downloaded VOD | MAD |
|---|---|
| input seek (`-ss` before `-i`) vs output seek (`-ss` after `-i`) | **0.000** |
| output seek vs `trim=start_frame=2232` | 19.697 |
| input seek vs `trim=start_frame=2232` | 19.697 |

Seeking is exact and agrees with itself both ways; `trim=start_frame` is the
outlier. **On files we encode ourselves all three agree at MAD 0.000**, which is
why the obvious control passed and the bad reference survived for hours.

Anyone verifying this code must compare **by timestamp**, and must validate the
comparison method against real source media rather than a synthetic stand-in.

Two further measurement notes, each of which cost an hour:

- The bundled FFmpeg has **no `psnr`/`ssim` filter and no `png` encoder**
  (`--disable-everything` plus an explicit enable list). Frame comparison must
  be done on raw `yuv420p`; rendering anything viewable needs a system FFmpeg,
  which is fine for measurement and must never be shipped.
- **A synthetic source with the frame index encoded in luma does not work.**
  `h264_videotoolbox` quantises flat frames hard enough that even 16-level
  steps read back with duplicates and a systematic lag *in the reference
  encode*. `testsrc`'s burnt-in counter shows seconds, not frames.

### 2.2 An explanation that is wrong

The source's frame timestamps are **millisecond-quantised** and ours are not.
An MP4 stores timestamps as integer ticks against a per-track timescale; ours is
15360, which is exactly 512 ticks per frame at 30 fps. The source's land on
whole milliseconds, and 1000 ÷ 30 is not an integer, so each frame rounds. The
grid is exactly `ceil(N × 1000 ÷ 30)` ms — **5998 of 5998 frames, no
exceptions** (`round` matches 3999, `floor` 2000).

This is real, it is analytic, and **it causes nothing.** The error is bounded at
±0.67 ms and does not accumulate, because the average is exactly 30 fps and it
resets every third frame. An earlier draft blamed the misalignment on it; there
was no misalignment. Do not re-adopt this explanation, and do not "fix" the
grids to match — nothing depends on them matching.

## 3. The retention area

Partial composites live in **`root/resume/<jobid>/`**, not in the job workspace.

`Workspace.removeAll()` is untouched: still unconditional, still scoped to
`jobs/`, and its comment — *"Nothing in it can ever be reused, so there is no
case to reason about and no way for a power loss to leak tens of gigabytes"* —
stays literally true. That guarantee's value is that it **cannot be wrong**, and
replacing it with a rule would trade that away. All new and fallible reasoning
is confined to a new directory that starts empty and holds exactly one kind of
thing.

This also avoids disturbing a coupling that is easy to miss.
`QueueEngine.removeJobWorkspace`'s second case is *deliberately* leaky and says
so: *"One chat file per cancelled job is bounded, and `Workspace.removeAll()`
sweeps it at the next launch anyway."* Weakening the sweep would silently make
every cancelled job's workspace permanent. Nothing here weakens it.

`Workspace` gains:

- `resumeDirectory(_ job: JobID) -> URL`
- `removeResumable(_ job: JobID)`

**One trap to make deliberate rather than accidental.**
`Workspace.contains(_:ofJob:)` is what `removeJobWorkspace` uses to tell an
intermediate from a delivered file. A file under `resume/` reports `false`,
which happens to produce the behaviour we want. Relying on that accident is how
this breaks in six months; it needs an explicit comment saying the resume area
is deliberately outside the job workspace and why.

## 4. The composite writes pieces

`QueueEngine.makeContext` points the composite's output at
`resume/<jobid>/piece-N.mp4` rather than `artifacts/`.

**A first attempt also writes `audio.m4a`.** FFmpeg accepts several outputs in
one invocation, so the same command that encodes piece 0 stream-copies the
source's audio track beside it — no extra process and no measurable time, since
it is a copy. This is what lets §5 delete the re-fetched video before
assembling: without it the 16.3 GB source would have to survive until delivery
purely to supply its audio, and the recovery peak would be ~74 GB rather than
~58. Resumed attempts do not re-extract it; they only hold the tail.

`StepContext` gains:

- `resumeFrom: Duration?` — the seek point, `nil` on a first attempt
- `existingPieces: [URL]` — what is already on disk

`ArgumentBuilder` stays pure: it emits `-ss` when handed a `resumeFrom` and
otherwise emits exactly what it emits today. Everything geometric is unchanged.

## 5. The recovery sequence

When a composite step launches and its resume directory holds pieces:

1. **Repair the last piece** — truncate after the last complete `mdat`. Only the
   last piece can be torn, and only if the interruption was not a clean exit.
2. **Count frames across all pieces.** The resume point is
   `totalFrames ÷ framerate`, seconds — a timestamp, per §2.
3. **Verify the source** (§7).
4. **Encode the tail** from `-ss resumePoint` into the next piece.
5. **Delete the re-fetched video and chat render.** Load-bearing for disk, see
   below. Both can go because the audio was copied out on the first attempt
   (§4); without that the video would have to survive to delivery.
6. **Assemble** (§6), deliver, and clear the resume directory.

Step 5 is what keeps the peak reasonable. Six-hour numbers, from
`compositing.md` §9 (video 16.3 GB, render 10.2, output 29.0, today's peak
55.5):

| Recovery phase | On disk |
|---|---|
| After the crash and launch sweep | 26.4 GB — piece 0 plus the copied audio |
| Re-fetch and tail encode | 26.4 + 16.3 + 10.2 + 3 = **55.9 GB**, about a normal run |
| After deleting the re-fetched inputs | 29.4 GB — both pieces plus audio |
| Assemble into the delivered file | 29.4 + 29 = **58.4 GB** |

Six hours of AAC at 160 kb/s is ~430 MB, which is why copying it out is worth
16.3 GB of headroom.

So recovery peaks at ~58 GB against a normal run's ~55.5 — **4.5% worse, not
additive.** It does not reach zero: a disk that could not hold 55.5 will not
hold 58, so recovering from a disk-full failure still requires the user to free
something. That is honest and quantifiable, and it is what the preflight in
`compositing.md` §10 exists to say.

## 6. The assemble step

Joining pieces is a second subprocess, and `QueueEngine.launch` runs exactly one
per step. So `.assemble` becomes a real `StepKind`, always present, depending on
the composite.

- **One piece** (every job that never failed): a `-c copy` concat of a single
  input, plus the audio from `audio.m4a`.
- **Several pieces**: the same, with more inputs in the list.

It depends on the composite step alone. It does **not** need the media step:
the audio it maps comes from `audio.m4a` in the retention area, not from the
downloaded video, which by then is deleted.

It is **not** a byte-append. `fragmented-output.md` §2 measured AVFoundation
reading only 305 samples of a byte-appended file where FFmpeg reads 901, even
with every `tfdt` hand-patched onto the right timeline. One encoder writing
continuously is fine; joining two encoders' output by concatenating bytes is
not. The concat demuxer produces a correct file; byte-appending does not.

**The alternative was a post-process inside `QueueEngine.finish`**, which avoids
adding a row to every composite job. Rejected: it puts a second process launch
somewhere that has never launched one, and it hides the step that actually
produces the user's file. An extra row that usually does nothing visible is
better than an invisible step that sometimes does a lot.

## 7. Failure semantics

**Pieces are never delivered.** Only the assemble step's output is. The rule
from `fragmented-output.md` §5 stands unchanged and matters more here, because
there are now several playable partial files rather than one.

**Source drift refuses rather than repairs.** Piece 0 records the downloaded
video's **byte length and duration**. On resume, after re-fetching, they are
compared; a mismatch fails the job with "the source changed since this download
started" and requires a fresh run.

This exists because Twitch mutes VOD sections for DMCA after the fact, and
renditions can be re-encoded or a VOD trimmed. Half a video from before a mute
and half from after produces a file with a discontinuity and **no error
anywhere** — the encode succeeds, the concat succeeds, and the result is subtly
wrong. Refusing is the same instinct as `hstack` declining mismatched heights
rather than producing a subtly wrong 22 GB file (`compositing.md` §5). Geometry
drift already fails loudly on its own; byte length is the cheapest signal that
catches the same-geometry, different-content case.

**Piece count is capped at 4.** Past that, a retry restarts from scratch. Each
seam is an encode boundary, and more importantly a job that has failed four
times is reporting something that resuming will not fix. Accumulating pieces
turns a persistent fault into a slowly degrading file instead of a clear
failure.

## 8. Retention lifecycle

**User-cleared, for now.** A job's resume directory is removed when:

- the job delivers successfully,
- the user dismisses or removes the job from the queue,
- the piece cap is hit and the job restarts from scratch.

It is **not** removed at launch. That is the whole point.

The failed row therefore **shows the retained size** — "Failed — 26 GB held,
dismiss to reclaim." That is what keeps user-cleared honest: the bytes are
visible and attributable rather than an invisible leak, at the cost of a
directory size lookup.

A total-bytes ceiling that drops oldest-first is the obvious next layer and is
deliberately deferred. This is an edge case, and bounding it by policy before
anyone has hit it is optimising a failure path at the expense of shipping.

## 9. What changes, and what does not

**`Reconciler` and `Scheduler` need no changes**, which is the strongest signal
that this design fits. Both currently assert that resume does not exist, and
both do so about *artifact bookkeeping*: they null a step's `artifact` on
interruption or retry. An unfinished composite never set one. **The resume state
is not in the queue at all — it is the presence of pieces in a directory**, and
`Reconciler` already reconciles against disk.

| Unit | Change |
|---|---|
| `Workspace` | `+ resumeDirectory`, `+ removeResumable`; `removeAll()` untouched; `contains(_:ofJob:)` gains the §3 comment |
| `StepContext` | `+ resumeFrom: Duration?`, `+ existingPieces: [URL]` |
| `ArgumentBuilder` | `.composite` emits `-ss` when given a resume point; new `.assemble` argv |
| `StepKind` | `+ case assemble`, `.compute` resource |
| `JobTemplate.makeJob` | appends `.assemble` depending on the composite alone |
| `QueueEngine` | composite output into the resume area; repair, frame count, source verification, input deletion, resume-directory lifecycle |
| `Reconciler`, `Scheduler` | **none** |

## 10. Not in scope

- A retention ceiling (§8), deferred deliberately.
- Resuming anything other than the composite. A download or a chat render that
  dies is minutes, not seventy of them.
- Segmenting the composite. `composite-performance.md` §4.3 measured it as no
  faster, and `fragmented-output.md` §2 shows it would cost the playable partial
  file.
- The disk-space preflight, still `compositing.md` §10's most valuable unbuilt
  item and still independent of this.

## 11. Testing

| Unit | Covered by |
|---|---|
| Torn-file repair | a file cut mid-fragment; one cut after a complete `mdat`; a file whose last box is a `moof` with no `mdat`; a file with no complete fragment at all |
| Resume point | `totalFrames ÷ framerate` across one piece and several; the §2 invariant that it is a timestamp and survives CFR fill |
| `ArgumentBuilder` `.composite` | `-ss` present with a resume point and absent without; the `-movflags` from `fragmented-output.md` §3 unchanged; the two GPL rules still hold |
| `ArgumentBuilder` `.assemble` | one piece → rename; several → concat plus `-c copy` and the audio mapped from the source |
| Source verification | matching length and duration resumes; either mismatched refuses with the §7 message |
| Piece cap | a fifth attempt restarts from scratch and clears the directory |
| `Workspace` | `removeAll()` does not touch `resume/`; `removeResumable` does; `contains(_:ofJob:)` reports `false` for a resume-area file |
| `JobTemplate.makeJob` | the assemble step and its dependency edge, both intake shapes, ×2 for clips |
| `Reconciler`, `Scheduler` | existing tests must still pass unchanged — that is the claim in §9 |

Plus one end-to-end run: composite a real VOD, kill the app mid-encode, relaunch,
retry, and verify the delivered file against a straight-through encode **by
timestamp** (§2.1). The same bar `compositing.md` §9 set for itself.
