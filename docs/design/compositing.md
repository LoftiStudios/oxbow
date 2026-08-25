# Compositing the VOD and chat into one video — design

**Status:** approved 2026-08-25. Not yet implemented.

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

1. **Video**
2. **Video + chat**

Applied symmetrically to clips: clip, or clip + chat. A clip composite is
seconds of work, so there is no reason to withhold it.

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
| Chat height | = video height | 1080 | 720 | 480 |
| Output width | video width + chat width | 2280 | 1520 | 1014 |
| Chat framerate | the video's, halved when it is 60 | 30 | 30 | 30 |
| Render bitrate | flat 12 Mbps at every quality — see below | 12M | 12M | 12M |
| Composite bitrate | seeded from `StreamQuality.bitsPerSecond` | — | — | — |

**3/16** is chosen because it lands on exact even integers at every standard
Twitch width, so the even-width rule never actually bites in practice. It is
enforced anyway, at the point of derivation and with a comment, because section
2 shows the encoder's response to an odd width is a silent one-column crop
rather than an error.

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

### The one number not derived here

**Font size.** The default of 12 was chosen for a 350x600 standalone render.
What is right in a 360x1080 column inside a 2280-wide frame is a question
answered by rendering one and looking at it, not from first principles. It is a
task in the implementation plan, not a ratio invented in this document.

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

The argv, verified in section 2:

```
ffmpeg -nostdin -y -hide_banner
  -i {video} -i {render}
  -filter_complex "[0:v]setpts=PTS-STARTPTS[v];
                   [1:v]setpts=PTS-STARTPTS,fps={framerate}[c];
                   [v][c]hstack=inputs=2[out]"
  -map "[out]" -map "0:a:0?"
  -c:v h264_videotoolbox -b:v {bitrate}M -pix_fmt yuv420p
  -c:a copy
  -progress pipe:1 -nostats -loglevel error
  {output}
```

Every element is load-bearing:

- **`setpts` precedes `fps`** so the rate conversion runs on a zero-based
  timeline.
- **`hstack`, not `pad` + `overlay`.** The tolerant alternative accepts a
  mismatched chat render and produces a subtly wrong 22 GB file with a black
  band under the chat. `hstack`'s strictness is the feature: a one-second
  failure instead of a seventy-five-minute one.
- **No `shortest=1`.** Chat renders end at the last message. A stream that goes
  quiet for its final twenty minutes would have had its *video* truncated. This
  is a real defect in the Ruby prototype this design replaces.
- **No `scale` on either input.** The chat is rendered at the right size by the
  render step; the video is already native. The prototype's `scale=w:h` to the
  source's own dimensions ran swscale over every frame for nothing.
- **`-c:a copy`, not a re-encode.** VOD audio is already AAC in MP4.
- **`0:a:0?`** — the `?` makes the map optional so a silent VOD does not hard
  fail. It must be quoted in a shell; `ArgumentBuilder` passes argv directly, so
  this only matters when reproducing by hand.
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
composite — which needs no model change at all. It was rejected because it
serialises a `.network` step against a `.compute` one, which is the exact
overlap `ResourceClass` exists to provide: roughly 74 minutes instead of 54
before the composite even starts on a six-hour VOD. It also inverts `makeJob`'s
standing invariant that "a failed video download must not block the render, and
vice versa."

**Wall-clock time is the binding constraint on this feature.** A six-hour stream
is already ~75 minutes of compositing. Any design choice that trades time for
anything else loses by default.

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
way: no clock, no I/O. `-progress pipe:1` emits repeating blocks of thirteen
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
| `Oxbow/Intake/RenderOptionsView.swift` | 157 | No render options remain |
| `Oxbow/Intake/HexColor.swift` | 60 | Its only consumer was that view's colour wells |
| `OxbowTests/HexColorTests.swift` | 103 | With it |

From `IntakeModel`: `isDownloadingChat`, `isRenderingChat`, `chatFormat`,
`renderOptions`, `renderIsInvalid`, `renderProblems`, `deliveredChatFormat`, and
`hasSelectedOutput`, replaced by one two-case enum. `IntakeSheet`'s three
toggles become a picker. `IntakeModelTests` (882 lines) is pruned heavily.

**`OutputSuffix` loses `.chat` and `.render`**, dropping `longestBytes` from 12
to 4. This *loosens* `OutputNaming`'s truncation reserve — titles may now be
eight bytes longer — and `IntakeModelTests` asserts `longestBytes == 12`
explicitly.

**`ChatFormat` and `JobTemplate.renderInput` survive**, though intake no longer
exercises them. `JobTemplate` is public library surface, and a caller composing a
template directly still needs the guard that a render's chat input is JSON.
Deleting it saves nothing at runtime and removes a safety net that landed one
day earlier.

## 9. Testing

| Unit | Covered by |
|---|---|
| `FFmpegProgressParser` | the thirteen-key block; blocks split mid-chunk; `progress=end`; `speed` -> `remaining`; `speed=0` guarded; `out_time_us=N/A`; missing keys |
| `ArgumentBuilder` `.composite` | the exact filter graph, `-nostdin`, `-c:a copy`, `0:a:0?`, absence of `+faststart`; the two GPL rules still hold |
| `Scheduler.admissible` | a two-parent step is not admitted until both parents are `.done` |
| `Scheduler.retry` | retrying one failed parent does not requeue a step whose other parent is still failed |
| `Scheduler.blockDependents` | failing either parent blocks the composite |
| `Step` decoding | a persisted scalar `dependsOn` decodes to a single-element array |
| `JobTemplate.makeJob` | both intake shapes, x2 for clips; the composite's two dependency edges |
| Geometry derivation | width/height/framerate per standard quality name; even-width forcing; empty quality resolving to `qualities.first` |
| `OutputNaming` | `longestBytes` 12 -> 4 and its effect on truncation |
| `QueueEngine` | `.composite` spawns `ffmpegPath`, not `helperExecutable` |
| `FailureInterpreter` | the real height-mismatch stderr from section 2, with the `[component @ 0x…]` prefix stripped |

Plus one end-to-end run against a real VOD before this is called done — the same
bar `chat-and-render.md` §2 set for itself.

## 10. Known and unbuilt

**Piping the chat render's raw frames into the composite.** The CLI already
pipes raw BGRA to its own FFmpeg, and we control `--output-args`, so
`{save_path}` could point at a FIFO carrying `-f nut -c:v rawvideo` that the
composite reads as its second input, concurrently. This eliminates an H.264
encode, a decode, and a multi-GB intermediate, and overlaps the render with the
composite: **~1.7x faster wall clock**, and the chat column would be encoded
exactly once from pristine frames rather than twice.

It is not built because it is the riskiest thing considered: 350x1080@60 BGRA is
~90 MB/s through a pipe, the two processes become hard-coupled so a stall in
either blocks the other, FIFO cleanup on cancellation is nasty, and it requires
two `.compute` steps running simultaneously — which breaks `Scheduler`'s
one-per-class rule and trips the warning `ResourceClass` already carries about
blocking syscalls pinned on the cooperative pool.

It is a **pure optimisation of this design**: same deliverable, same filter
graph, same user-facing behaviour. It can land later on evidence. Given that
wall-clock time is the binding constraint (§6), it is the most valuable
unbuilt thing here.

**`hevc_videotoolbox`** is present in our build and would roughly halve the
22 GB at equal quality and essentially equal speed on Apple Silicon's media
engine. It does not help the binding constraint and it costs playback
compatibility off-Apple, so it is recorded rather than shipped.

**An AVFoundation composition** was considered as an alternative to FFmpeg.
`AVMutableVideoComposition` with two layer instructions and a translation
transform needs no custom compositor and would keep frames as `CVPixelBuffer`s
on the GPU — FFmpeg on macOS has no VideoToolbox filter family, so `hstack`
forces a decode -> CPU -> encode round trip on every frame. It was rejected
because `QueueEngine` assumes every step is a subprocess, so a step that is not
one is a deeper change than a step that spawns a different binary, and because
4.79x realtime is measured while AVFoundation's advantage is theoretical.

## 11. Not in scope

- Overlaying chat on top of the video instead of beside it, and any other
  frame layout. One shape, chosen deliberately.
- User-configurable chat appearance. Deleted on purpose (§8).
- Compositing an already-downloaded VOD with an already-rendered chat. Every
  composite runs as part of a job that produced both inputs.
- Vertical or "shorts" layouts.
- Burned-in subtitles, alerts, or any other overlay.
