# Fragmenting the composite's output — design

**Status:** approved 2026-08-26. **§3 implemented** — the `-movflags`
fragmentation flags, added during the resume branch's Task 6 because resume is
impossible without them — and verified end to end (`resume.md` §2). **§5's
failure invariant already holds**, unchanged, in the pre-existing
`FailureInterpreter` (a non-zero exit is rejected regardless of whether an
artifact exists), but has no dedicated test pinning it down for a fragmented,
now-playable partial file specifically, which §9 calls for. **§6's affordance
is built, in a narrower shape than designed here.** A context menu on the
composite step's own row (`StepRow`, one item, "Show in Finder") reveals the
job's **retained pieces** (`QueueEngine.retainedFileURLs(forJob:)`, wired
through `QueueController`) — not the in-progress *file* this section
describes, since resume (§8, since built) is what turned that working file
into a directory of numbered pieces rather than one growing file. It selects
the pieces themselves, falling back to the (always-created once the step has
started) retention directory when there are none yet — so the first of §6's
two rough edges no longer applies: the retention area holds only the
composite's own pieces, never the video, the chat JSON, or the chat render.
The second rough edge (the overstated duration) is unaffected — still true of
whichever piece a player is pointed at. Enablement started as the flat boolean
`JobPresentation.hasStarted(step.status)` — running or settled by any means —
but that broke once a job could fully deliver and have its retention area
deleted out from under a `.done` composite step: the item stayed enabled,
pointing at a directory that no longer existed. `QueueEngine.revealTarget(forJob:)`
replaced it with a filesystem-backed answer: the retention area if it is
still on disk, the delivered file (the `.assemble` step's artifact) once
that area is gone because the job succeeded, otherwise nothing — with the
item present and disabled only in that last case.

Prerequisites: `docs/design/compositing.md` (the step this changes) and
`docs/composite-performance.md` (why the composite takes as long as it does, and
why that is not fixable).

---

## 1. What this delivers, and why it is not the preview

`ArgumentBuilder`'s `.composite` case gains one option — `-movflags` — so the
composite writes a **fragmented MP4** instead of a conventional one.

The visible consequence is that the in-progress file is playable while it is
still being encoded. **That is a side effect, not the reason.** The reason is
that a fragmented MP4 has *valid partial state*, and a conventional one has
none:

| | Conventional MP4 | Fragmented MP4 |
|---|---|---|
| Layout | `ftyp` · `mdat` (all frames) · `moov` (index of every frame) | `ftyp` · empty `moov` · `moof`+`mdat` · `moof`+`mdat` · … |
| Index written | at the very end, when offsets are known | per fragment, as it goes |
| A file cut at 70% is | undecodable — there is no index | 70% of the video, exactly |

The composite takes ~74 minutes on a six-hour stream and nothing will make it
faster (`composite-performance.md`). A step that long, run unattended, needs a
way to survive dying at minute 70 — and **there is nothing to resume from
unless the partial file is well-formed**. This change is the precondition for
that (§8). The preview is what falls out along the way.

It is deliberately *not* surfaced as a feature. A download application that
launches a video player is at odds with itself: the use case is watching on a
plane or archiving, not watching minute three now. §6 buries it accordingly.

## 2. Verified before designing

Measured 2026-08-26 on the same rig and inputs as `composite-performance.md` §2
— M1 Max, the bundled LGPL FFmpeg 8.1.2, and a real 547s VOD compositing to
2166x1026 @ 30 at 10 Mbps.

**It costs nothing:**

| | Conventional | Fragmented |
|---|---|---|
| Encode wall clock | 48.72s | **49.01s** |
| Output size | 708,772,840 B | **708,772,963 B** (+123) |
| Index overhead | `moov` 474,700 B — **0.067%** | `moov` 2,026 + `moof` 410,560 + `mfra` 51,453 = 464,039 B — **0.065%** |

The index is *smaller* fragmented: the sample table disappears from `moov` and
reappears distributed across the fragments, plus a trailing `mfra` random-access
index. It scales with frame count either way, so a six-hour file behaves the
same.

**A partial file reads exactly as far as its bytes go:**

| Bytes present | Content readable |
|---|---|
| 10% | 54.37s of 547 |
| 25% | 135.57s |
| 50% | 270.37s |

Cut mid-fragment, with no index and no clean ending, AVFoundation still returns
everything complete before the cut. Fragment granularity is **~0.4s** — 1351
fragments across 547s — so the readable edge trails the encoder by under half a
second.

**And it can be read while FFmpeg is still writing it.** Three successive opens
of the same growing file during one encode returned 148 samples (4.80s), 232
(7.60s), and 388 (12.80s). No locking, no corruption, `readyToPlay` throughout.

**The finished file is fully seekable.** FFmpeg writes an `mfra` index on close;
seeks to 5s, 15s, and 25s all landed exactly.

**The in-progress file is not, past its written edge.** With ~136s written of a
declared 547s:

| Seek | Result |
|---|---|
| 30s | exact |
| 120s | exact |
| 300s | **"Cannot Open"** |
| 540s | **"Cannot Open"** |

It reports `duration=547s` and `seekable=0–547` regardless — the header is
written before any content exists, so it necessarily overstates. A player shows
a full-length scrubber and errors rather than clamping when dragged past the
live edge. Nothing can be done about this; §6 sets expectations instead.

### What does not work, recorded so it is not retried

**Byte-appending two independently encoded fragmented files does not work.**
Three 10s segments, stripped of their own `ftyp`/`moov` and with all 27 `tfdt`
boxes each patched to the right timeline offset, produce a file FFmpeg reads
correctly at **901 frames / 30.03s** — and that AVFoundation truncates at
**305 samples / 10.03s**, the exact first seam, on linear decode as well as
seeking. Three ways of making FFmpeg emit the offsets itself
(`-output_ts_offset`, `-copyts`, `-avoid_negative_ts disabled`) all failed the
same way: `movenc` rebases the first fragment to zero regardless.

This is the same failure family as `composite-performance.md` §4.5 — valid
ISO-BMFF that AVFoundation declines to follow. **One encoder writing
continuously is fine; joining two encoders' output is not.** It is why §8's
resume concatenates properly rather than appending bytes, and why segmenting the
composite into N parallel steps would cost the playable partial file.

## 3. The change

`ArgumentBuilder.arguments(for:context:)`, `.composite` case, gains one option
before the output path:

```
-movflags +frag_keyframe+empty_moov+default_base_moof
```

- **`empty_moov`** writes the track declarations with no sample table, so the
  file is structurally valid from byte 0 rather than only at the end. This is
  the flag that does the work.
- **`frag_keyframe`** starts a fragment at each keyframe, which sets the ~0.4s
  granularity measured above.
- **`default_base_moof`** makes each fragment's data offsets relative to its own
  `moof` rather than to the file, so a fragment is self-contained.

`+faststart` remains forbidden. `compositing.md` §5's reasoning is unchanged —
it rewrites the whole file to relocate the `moov` — and fragmentation makes it
meaningless anyway, since there is no monolithic `moov` to relocate.

Nothing else in the argv changes. The chat render's `--output-args` is a
different path and is untouched: its output is an intermediate that only the
composite consumes, so it gains nothing from being fragmented.

## 4. The delivered file stays fragmented

The alternative is a `-c copy` remux to a conventional MP4 before delivery,
which costs **0.86s per 709 MB** — about 35 seconds on a six-hour output. That
is not the reason to decline it. The reason is disk: a remux holds a second full
copy of the output, ~29 GB on a six-hour job, against a peak that
`compositing.md` §10 already identifies as the feature's one live failure mode.
Paying 29 GB to change a brand is a bad trade.

And nothing on macOS can tell the difference. Measured:

| Check | Fragmented | Conventional |
|---|---|---|
| Quick Look thumbnail | byte-identical, 271,040 B | identical |
| Spotlight (`kMDItemDurationSeconds`, `kMDItemPixelWidth`, `kMDItemVideoBitRate`) | 547 / 2166 / 10329 | identical |
| `AVAssetExportSession` compatible presets | 23 | 23 |
| Passthrough re-export | succeeds | succeeds |
| Seeking | exact | exact |

The only byte-level difference in the delivered file is the `ftyp` brand:
**`iso5` fragmented, `isom` conventional.** That is the one thing a strict
third-party tool could key on, and nothing on this machine did.

**Not verified:** non-Apple players and upload pipelines. Fragmented MP4 is the
container underneath HLS and DASH, so it is about as widely handled as a format
gets — but that is an argument, not a measurement, and this document's own
history is three plausible arguments that measurement killed. If a real
compatibility complaint appears, the remux above is a 35-second step that bolts
on without disturbing anything else here. That is the escape hatch, and it is
cheap; do not pre-emptively build it.

## 5. Failure semantics do not change

**A composite that exits non-zero is still rejected, however playable its output
file is.**

`FailureInterpreter` today treats any non-zero exit as failure *regardless of
whether an artifact exists*, so a composite that died at 90% is never moved to
the user's folder (`compositing.md` §7). This change makes that partial file
genuinely watchable, which makes delivering it much more tempting — and it must
still be discarded.

The distinction that matters: **the workspace file is a preview, not a
deliverable.** A user who asked for a video did not ask for 90% of one under the
name of a whole one, and the failure that truncated it is exactly the case where
they cannot tell by looking. The same holds for cancellation: `HelperProcess`
sends SIGTERM before SIGKILL so FFmpeg closes its output cleanly, which now
leaves a valid partial file, and it is still discarded with the workspace.

This is written down because it is the kind of invariant a later change
"improves" in good faith. §8's resume is the correct way to salvage a partial
composite; delivering it is not.

## 6. The affordance, deliberately buried

A context-menu item on the composite **step's** row — the queue list already
expands a job into its steps — that reveals the in-progress file in Finder. That
is the idiom Transmission uses, and the one a download application should
borrow. Not a button, not a player, nothing visible on the row until you
right-click it.

**Reveal, not open.** `NSWorkspace.activateFileViewerSelecting` selects the file
in Finder and leaves the decision to the user, which is what the Transmission
idiom actually does. Launching a player from a download queue is the thing §1
argues against.

Two known rough edges, both accepted:

- The workspace folder also holds the downloaded video, the chat JSON, and the
  chat render. Revealing selects the composite specifically, but the
  intermediates are visible alongside it. Acceptable for an affordance this
  deliberately obscure; it is not the primary path to anything.
- The file overstates its duration (§2), so a player's scrubber will show the
  full length and error past the live edge. The menu item's wording carries that
  expectation rather than pretending otherwise.

## 7. Not in scope

- **Segmenting the composite into N steps.** §2 records why it would cost the
  playable partial file, and `composite-performance.md` §4.3 records why it buys
  no speed.
- **Resume.** §8 is the follow-on, decided separately.
- **The disk-space preflight.** Still `compositing.md` §10's most valuable
  unbuilt item and still unbuilt. It is independent of this.
- **Any change to the chat render's container.**

## 8. What this enables: resume

Recorded so the container choice reads as deliberate rather than incidental.

Because a partial fragmented file is valid and cut-able at a fragment boundary,
a composite that fails partway can in principle be salvaged: read back the last
complete fragment's timestamp, truncate the file there, encode only the
remaining tail, and concatenate the pieces at delivery with a proper `-c copy`
concat — **not** a byte-append, which §2 proves AVFoundation will not follow.

That would give retry granularity on the longest step in the application without
segmenting it, and without the queue growing N rows. It is undesigned, and it
introduces resume, which `Scheduler`'s own documentation notes does not exist
anywhere in this stack today. It is the next conversation, not this one.

## 9. Testing

| Unit | Covered by |
|---|---|
| `ArgumentBuilder` `.composite` | the exact `-movflags` value, in the right position; `+faststart` still absent; the two GPL rules from `compositing.md` §9 still hold |
| `ArgumentBuilder` `.renderChat` | unchanged — the render's `--output-args` gains nothing |
| `FailureInterpreter` | a non-zero exit is still `.failed` when an output file exists and is non-empty — the §5 invariant, asserted rather than assumed |

Plus one end-to-end run against a real VOD, checking that the delivered file
plays and seeks, and that the in-progress file is readable mid-encode. The same
bar `compositing.md` §9 set for itself.

## 10. Correction made elsewhere

`composite-performance.md` §7 said segmenting would buy "a much lower disk
peak" and implied early playback requires segmentation. Both were wrong, and
that section is corrected in the same change that adds this document:

- Independently encoded segments must be concatenated into the delivered file,
  so ~29 GB of segments and a ~29 GB result exist simultaneously — a peak of
  ~58 GB against today's ~55.5. Lower in the middle of the run, not at the peak.
- Early playback needs no segmentation at all. It needs `-movflags`.
