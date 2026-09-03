# Resuming an interrupted composite — design

**Status:** approved 2026-08-26. Implemented, with argv- and unit-level
coverage complete and green throughout, including the sidecar fix (§4): the
audio sidecar is not crash-safe the way the piece is, so instead of trying to
make it so, a resumed composite now rewrites it outright whenever it isn't
usable.

**Live confirmation against a real VOD is partial, not complete — read this
plainly rather than as "verified end to end."** The core resume mechanism
(§2 "Verified end to end") is fully confirmed live: piece survival, the
resumed seek, the seam, and the delivered frame count. The sidecar fix is
confirmed live on its **defect** half only: a genuine `SIGKILL` reproduced
the corruption for real — piece 0 survived and repaired at 4452 complete
frames, and the audio sidecar came back with no complete `moov`, exactly as
predicted. Its **recovery** half — that a resumed attempt notices and
rewrites the sidecar, and `.assemble` then delivers a file with correct,
synced audio — was **not** confirmed live. A Twitch platform outage on
2026-08-27 (independently confirmed via status.twitch.com and public outage
trackers, affecting video/chat/login broadly) cut the run short right after
it had reproduced the defect, before the resumed attempt could run. Re-run
`ResumeEndToEndTests` once Twitch is stable to get that remaining
confirmation.

Separately, and without depending on Twitch or the network at all,
`SidecarRewriteFFmpegTests` (§11) runs the real, `ArgumentBuilder`-generated
resume argv through the real bundled FFmpeg against a synthetic source and
confirms the specific mechanism the fix relies on: the rewritten sidecar
spans the **whole source**, not the tail. That is real-FFmpeg confirmation of
the fix's own claim, independent of the still-open live-VOD recovery
confirmation above — the two are not the same evidence, and neither
substitutes for the other.

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
at output time `N ÷ framerate`. The filter graph applies
`fps={framerate}:start_time=0` and no rate change to the video, so **output
time is source time**. Seeking the source to `N ÷ framerate` therefore lands on
the frame that becomes output frame N, regardless of how many frames CFR fill
inserted along the way.

**That sentence used to be false, and this is why the filter is not `setpts`.**
`setpts=PTS-STARTPTS` zeroed the video's own start timestamp, so output time
was source time *minus* whatever leading offset the download carried — 0.866s
on a trimmed VOD, because a `-c copy` trim can only start video on a keyframe
(`compositing.md`). The seek then read that offset as a gap. `fps` pads the
head instead of shifting the track, which makes the claim above hold literally.

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

### Verified end to end

Task 11, 2026-08-27. Headless — `StepContextBuilder.make` and `ArgumentBuilder`
driven directly against `build/helper/TwitchDownloaderCLI` and
`build/ffmpeg/ffmpeg`, against a real 120s slice of the same VOD, with a
genuine `SIGKILL` (not `HelperProcess.cancel()`'s `SIGTERM`) fired at 60% of
the encode by content position. `Tests/OxbowKitTests/ResumeEndToEndTests.swift`,
gated behind `OXBOW_RESUME_E2E=1` — not part of the default `swift test` run.

| Question | Answer |
|---|---|
| Does the killed piece survive the launch sweep? | **Yes.** 2280 complete frames repaired and readable; `jobs/` gone, `resume/` intact. |
| Does the second attempt seek rather than restart? | **Yes.** `-ss 76.0`, wall clock 4.6s against the killed attempt's 7.1s. |
| Is the seam correct, by timestamp? | **Yes.** MAD 1.74 at the seam, 12.27 one frame off — the same clean separation the design spike measured. |
| Does the delivered frame count match a straight-through encode? | **Within a few frames, not exactly.** Delivered 3603, reference 3601. Chased down, not waved away: `video2` decoded alone splits perfectly at the seek point (2262 + 1310 = 3572, matching one continuous decode), so this is not a seek-accuracy bug. The composite's CFR gap-fill (this section, above) is computed from each piece's own `setpts=PTS-STARTPTS` zero point independently, so splitting the timeline can shift where a fill decision lands relative to one continuous pass — the same way splitting a sum changes floating-point rounding. Bounded at a few frames (a fraction of a second) on this run; the seam MAD is what actually rules out lost or duplicated *content*. Worth knowing, not urgent: this means a resumed delivery is not always bit-for-bit frame-identical to a from-scratch encode of the same range, which nothing above previously said. |

**A real defect, found by this run, and since fixed:** the audio sidecar
(§4's `audio.m4a`) has none of the fragmentation that makes a piece survive a
crash. It is an ordinary MP4, written by the *same* FFmpeg invocation as
piece 0, and a conventional MP4's index is written once, at the very end — so
`SIGKILL`ing that invocation, at any point before it finishes naturally,
leaves `audio.m4a` with no `moov` atom at all. Confirmed at 93% through the
encode, not just early: still corrupt. A graceful `SIGTERM` (what
`HelperProcess.cancel()` and an app quit actually send) does **not** trigger
this — FFmpeg finalises both outputs cleanly on `SIGTERM`, which is resume.md
§2's own "easy case." Only a genuine crash or power loss does, which is
exactly the case fragmentation exists for (§1: "app quit, crash, closing the
laptop, reboot") — and only the piece got that protection, not the sidecar.

The old gate made this worse than it had to be: `ArgumentBuilder` wrote the
sidecar only when `resumeFrom == nil`, i.e. only on a first attempt, so a
sidecar corrupted by a crash was never rewritten by any later one. Every
subsequent retry re-encoded the tail successfully and then failed at
`.assemble` on the same corrupt file, until the piece cap (§7) forced a
restart from scratch. No wrong file was ever delivered —
`.assemble`'s non-zero exit is caught the same as any other step failure —
but a crash during the single longest attempt of the composite, arguably the
likeliest moment for one to land, lost the recovery this feature exists to
provide, for exactly the class of interruption §1 leads with.

**The fix is not the fragmentation flags this section originally proposed.**
Fragmenting the sidecar the way the piece is fragmented would need its own
resume logic — tracking how much of the audio track survived, seeking the
source to the matching point, splicing the old and new audio — for a file
that is a plain stream copy and cheap to redo outright. So instead: §4 now
gates the sidecar on whether a *usable* one already exists
(`FragmentedMP4.hasCompleteMoov`, decided by `QueueEngine` and handed to the
pure `ArgumentBuilder` as `StepContext.hasUsableSidecar`), not on attempt
number. A resumed composite whose sidecar is still missing or corrupt
rewrites it in the same invocation that resumes the video — via a **third,
un-seeked** copy of the source input, since the two composited inputs are
seeked to the resume point and mapping audio from either of those would
truncate the sidecar to the tail. Covered by unit and argv-level tests in
`FragmentIndexTests`, `ArgumentBuilderTests`, and `QueueEngineTests`, all
green.

**Live re-verification is partial, not because the fix failed but because
Twitch itself did.** A second headless run (`ResumeEndToEndTests`, same
method as above) reproduced the defect for real: a genuine `SIGKILL` fired at
`out_time_us=74400000` (72.0s target), wall clock 14.17s; piece 0 survived
with 4452 complete frames after repair; and the audio sidecar afterward was
confirmed corrupt exactly as predicted — 1,310,791 bytes, unreadable,
`hasCompleteMoov == false`. The run could not continue past that point: a
widespread Twitch platform outage began during this work on 2026-08-27
(independently confirmed via `status.twitch.com` and public outage trackers,
affecting video, chat and login broadly — not specific to this VOD, this
helper, or this repository) and did not clear during the session. So the
fix's own live confirmation — that the resumed attempt's rewritten sidecar is
usable and `.assemble` delivers a file with correct, complete, synced audio —
is proven by argv and unit tests but **not yet confirmed against the real
helper end to end.** Re-run `OXBOW_RESUME_E2E=1 swift test --filter
ResumeEndToEndTests` once Twitch is stable; the test now asserts the full
chain, including the delivered file's audio/video sync.

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

`StepContextBuilder.make` points the composite's output at
`resume/<jobid>/piece-N.mp4` rather than `artifacts/`.

**`audio.m4a` is written whenever no usable one exists yet — not only on a
first attempt.** FFmpeg accepts several outputs in one invocation, so the same
command that encodes a piece stream-copies the source's audio track beside
it — no extra process, and on a **first** attempt no measurable time either,
since it is a copy and input 0 is already the un-seeked source the copy needs.
This is what lets §5 delete the re-fetched video before assembling: without
it the 16.3 GB source would have to survive until delivery purely to supply
its audio, and the recovery peak would be ~74 GB rather than ~58.

On a **resumed** attempt that needs the rewrite, this is not quite free: the
two composited inputs are seeked and FFmpeg's demuxer can skip straight to
their start, but the third, un-seeked input (below) reads the source from
byte 0 — a full sequential re-read of the 16.3 GB file that the seeked inputs
never pay for. Cheap next to a 74-minute encode running in the same
invocation, and bounded (it is I/O, not compute, and runs alongside the
encode rather than blocking it), but it is a real cost the "no measurable
time" framing above only holds for a first attempt.

**Unlike the piece, this output is not itself fragmented — that was a real
gap, found by §2's "Verified end to end," and it is fixed differently from
how this section originally proposed.** Fragmenting the sidecar the way a
piece is fragmented would need its own resume machinery for a file that is a
plain stream copy and cheap to redo outright, so instead the sidecar is
simply rewritten whenever it isn't usable, on whichever composite attempt
first notices — first or resumed alike. `QueueEngine` decides usability with
`FragmentedMP4.hasCompleteMoov` (the same no-decode box walk `FragmentIndex`
already does for pieces, checking for a complete top-level `moov` rather than
counting fragments) and hands the answer to `StepContext.hasUsableSidecar`;
`ArgumentBuilder` stays pure and just reads it.

A resumed attempt whose sidecar needs rewriting cannot map audio from either
composited input — both carry `-ss` to the resume point, and mapping from
either would truncate the sidecar to the tail, which is worse than leaving it
broken: a truncated sidecar desyncs silently instead of failing loudly. So
`ArgumentBuilder` adds a **third input**, the same source video again but
un-seeked, purely to supply the sidecar's audio map:

```
-ss T -i video.mp4  -ss T -i chatrender.mp4  -i video.mp4   ← input 2, un-seeked
```

On a first attempt input 0 is already un-seeked, so no third input is added —
the sidecar maps from `0:a:0?` exactly as before. `.assemble` then reads
whatever sidecar is on disk once the composite step has finished, whichever
attempt actually produced a usable one.

**Known quirk, not a bug: progress can read 100% before a resumed composite
actually finishes.** `FFmpegProgressParser` reports `out_time_us` as FFmpeg
itself reports it, which is the maximum across every output in the
invocation — not just the piece. On a resumed rewrite the sidecar output
spans the whole content window while the piece spans only the tail, so the
sidecar's own timestamps can momentarily lead the piece's, and the reported
fraction can approach or touch 1 while the video encode is still running.
FFmpeg's own dts balancing between outputs bounds how far this lead can run,
so it is a cosmetic tail effect on the progress bar, not a stall or a stuck
job — nothing here is out of sync, only the number that describes how close
to done it is. **Do not restructure progress reporting to fix this**; it is
recorded so a future reader recognises it as this, not as a regression. See
`Sources/OxbowKit/Parsing/FFmpegProgressParser.swift`.

`StepContext` gains:

- `resumeFrom: Duration?` — the seek point, `nil` on a first attempt
- `existingPieces: [URL]` — what is already on disk
- `hasUsableSidecar: Bool` — whether `audio.m4a` is already complete and
  playable; decided by `QueueEngine`, read but never computed by
  `ArgumentBuilder`

`ArgumentBuilder` stays pure: it emits `-ss` when handed a `resumeFrom`, emits
the sidecar output (and, on a resume, the third input) when handed
`hasUsableSidecar == false`, and otherwise emits exactly what it emits today.
Everything geometric is unchanged.

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

**Verified 2026-08-26 (Task 7): re-downloads are byte-stable.** Downloading
the same VOD twice gave byte length 419,847,127 both times and duration
00:09:07.01 both times — identical — while **the files themselves differ
byte-for-byte.** So the chosen signal is safe: it will not spuriously refuse a
valid resume. This also settles a fallback that might otherwise look more
rigorous — a content hash of the downloaded video cannot be the signal,
because a hash would differ on every re-download and refuse every valid
resume; byte length is not just cheaper than a hash here, it is the only one
of the two that actually works.

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
| `FragmentedMP4.hasCompleteMoov` | a finalised `ftyp`+`mdat`+`moov` file reads complete; a file killed before `moov` was ever written reads incomplete; a torn `moov` header with no room for its body reads incomplete; a `largesize` extended box past `Int.max` reads as malformed rather than trapping (`aLargesizeBeyondIntMaxDoesNotTrap`, and `index(of:)`'s own `indexToleratesALargesizeBeyondIntMax`) |
| `FragmentedMP4` against real FFmpeg output, not hand-built boxes | `readsARealFFmpegFragmentedFile` against a real fragmented piece; `aRealSigkilledAudioWriteHasNoMoov` (`FragmentIndexTests`) against `Fixtures/sigkilled-audio-sidecar.m4a`, a genuinely `SIGKILL`ed FFmpeg audio write whose `mdat` is left with the `size == 0` EOF-extension placeholder — the one branch of `FragmentedMP4` no hand-built fixture had exercised. The verdict is `false` either way, so this was not a live bug, only an untested branch |
| Sidecar usability gate | a first attempt (no sidecar yet) and a resumed attempt with a corrupt sidecar both write it, mapped from `0:a:0?` and a third un-seeked input respectively; a resumed attempt with an already-usable sidecar writes nothing; `QueueEngine` computes `hasUsableSidecar` from the real file on disk, corrupt or intact |
| The sidecar rewrite against real FFmpeg | `SidecarRewriteFFmpegTests` (network-free, default suite, skips cleanly if `build/ffmpeg/ffmpeg` is absent): the real `ArgumentBuilder`-generated resume argv, run through the real bundled FFmpeg against a synthetic rawvideo+PCM source built from `/dev/zero`, confirms the rewritten sidecar spans the whole source rather than the tail — the claim §4's argv-shape tests alone cannot make, since they never run FFmpeg |
| Source verification | matching length and duration resumes; either mismatched refuses with the §7 message |
| Piece cap | a fifth attempt restarts from scratch and clears the directory |
| `Workspace` | `removeAll()` does not touch `resume/`; `removeResumable` does; `contains(_:ofJob:)` reports `false` for a resume-area file |
| `JobTemplate.makeJob` | the assemble step and its dependency edge, both intake shapes, ×2 for clips |
| `Reconciler`, `Scheduler` | existing tests must still pass unchanged — that is the claim in §9 |

Plus one end-to-end run: composite a real VOD, kill the app mid-encode, relaunch,
retry, and verify the delivered file against a straight-through encode **by
timestamp** (§2.1). The same bar `compositing.md` §9 set for itself. Extended
to hard-kill the *first* attempt specifically (rather than a later one) so the
audio sidecar is left corrupt, and to assert that the resumed attempt notices
and rewrites it, and that `.assemble` then delivers a file with synced audio —
see §2's "Verified end to end" for why that extended assertion is not yet
confirmed against the real helper.

---

## 12. The chat render's own seek

A resumed composite seeks both of its inputs to the same instant. That is right
for the video and wrong, sometimes catastrophically, for the chat render.

**Chat renders do not always run as long as their video.** §4's filter graph
already knows this — it is why there is no `shortest=1`, and why `hstack`'s
`eof_action=repeat` holds the last chat frame for the rest of the video. A
stream that goes quiet twenty minutes before it ends produces a render twenty
minutes shorter, and that is ordinary, not pathological.

Seeking such a render past its own end yields **zero frames**. `hstack` cannot
repeat a frame that never arrived, so the graph produces nothing at all — and
FFmpeg **exits 0**. Measured with the bundled binary, a 60s video seeked to 30s
beside a 5s chat render seeked to 30s:

| chat length vs. seek | piece |
|---|---|
| chat 60s, seek 30s | 903 frames, 11.3 MB |
| chat 5s, seek 30s | no decodable frames, 1,785 bytes |
| chat 5s, seek clamped inside its end | 903 frames, 8.1 MB |

Exit 0 in all three. Nothing downstream noticed: `.assemble` concatenated the
empty piece as an empty segment and delivered a file truncated at the seam,
with no error anywhere in the pipeline. The end-to-end test in §11 had been
failing on exactly this, with `piece 1 = 1` against a reference of `7203`.

**So the two seeks are separate values.** `StepContext.chatResumeFrom` is the
resume point clamped to just inside the render's own end, which lands on its
last frame and lets `hstack` repeat it — precisely what a first attempt shows
at that point. `nil` means "the same as the video", which is the ordinary case
and the behaviour that was always correct for it.

### The margin is measured in the render's frames, not the composite's

This is the part that is easy to get wrong, and it fails silently when you do.

The two framerates are routinely different — normalising a 30fps render up to a
60fps video is one of the filter graph's jobs. A margin of one *composite*
frame (0.0167s at 60fps) lands **past** the last frame of a 30fps render, which
sits 0.0333s before the end. The seek then yields nothing and the piece comes
out empty exactly as if there had been no clamp at all. The first version of
this did that, and the end-to-end test failed identically before and after it,
which is what makes it worth writing down: a clamp that looks applied, prints
a plausible number in the argv, and does nothing.

`StepContextBuilder.make` therefore reads the framerate from the *render step's
own request* and uses two of its frames — one frame of tolerance either way.
The cost is that the seam replays two chat frames (67ms at 30fps) rather than
freezing on the last one. The cost of being one frame too late is the whole
tail of the delivery.

### Where the duration comes from

`FragmentedMP4.duration(of:)` reads `moov` → `mvhd`, the same no-decode box
walk the rest of that type uses. We bundle no `ffprobe` to ask, and a decode
would be absurd for one number. It returns `nil` rather than zero when it
cannot read a header: a caller clamping a seek must be able to tell "this
render is N seconds long" from "I could not find out", because those call for
opposite behaviour — clamp, or leave the seek alone.

### The guard that should have caught this

The defect survived because **the exit code said nothing and every existence
check agreed**. `QueueEngine.isUsableArtifact` already knows exit codes decide
nothing here, but "exists and is non-empty" is not sufficient for a piece: a
filter graph that yields nothing still writes `ftyp` and `moov`, so the file is
neither missing nor zero-length.

So a composite's piece is now checked for declared samples — `trun` carries the
count, so it is a box walk, not a decode — and a frameless piece fails the step
with "The composite produced no video." rather than being handed to
`.assemble`. Unreadable counts as frameless, for the same reason
`hasUsableSidecar` fails closed: a piece we cannot read is not one to give the
concat demuxer.

This guard is the general form. The chat seek was one way to produce an empty
piece; the guard covers the class.
