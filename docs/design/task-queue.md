# Task queue — design

**Status:** approved in outline 2026-08-23, pending written review.
**Scope:** the queue subsystem only. Not the forms, not the Xcode project.

`docs/development.md` says the task queue is the core abstraction and should be modelled
properly. This is that model. It covers what a unit of work is, how work is
admitted, how a CLI invocation is driven and cancelled, what survives a crash,
how failure is reported, and how all of it is tested.

---

## 1. Facts this design rests on

Every one of these was verified against `TwitchDownloaderCLI 1.56.5+d4122d8`
rather than assumed. Several of them overturned an earlier decision, so they are
recorded with their evidence.

### 1.1 Progress is carriage-return delimited

`CliTaskProgress.WriteSameLineMessage` emits `Console.Write('\r')`
unconditionally. There is **no** check for whether stdout is a TTY, so the
behaviour is identical when piped. Captured evidence, `chatrender` over a 40s
chat:

| Fixture | `\r` | `\n` |
|---|---|---|
| `videodownload-success.stdout` | 9 | 4 |
| `chatrender-success.stdout` | **401** | **4** |

A reader that splits on `\n` sees four lines for a render that reported 401
times. **The parser must split on `\r` and `\n`**, and must strip the trailing
padding spaces the CLI writes to overwrite longer previous lines.

### 1.2 Four status line shapes

All observed in real output:

```
[STATUS] - Fetching Video Info [1/4]                                 phase + counter
[STATUS] - Downloading 100% [2/4]                                    phase + pct + counter
[STATUS] - Downloading 25%                                           phase + pct
[STATUS] - Rendering Video 45% (0h0m0s Elapsed | 0h0m0s Remaining)   phase + pct + times
```

Six preambles exist: `[STATUS] - `, `[VERBOSE] - `, `[INFO] - `,
`[WARNING] - `, `[ERROR] - `, and `<FFMPEG> ` — note the last has no ` - `.

### 1.3 Resume is impossible

`VideoDownloader.cs:28`:

```csharp
_vodCacheDir = Path.Combine(_cacheDir, $"{downloadOptions.Id}_{DateTimeOffset.UtcNow.Ticks}");
```

The cache directory embeds a 100-nanosecond timestamp, so no two invocations
ever name the same directory. Nothing in the codebase looks for a previous
one — the only cross-run directory scan is `CleanupAbandonedVideoCaches`, which
*deletes* caches older than seven days.

**Consequence:** interrupted work restarts. There is no cache to preserve, so
there is no cache-management surface.

### 1.4 Cancellation cannot be graceful

Every mode passes a token that can never fire:

```csharp
videoDownloader.DownloadAsync(new CancellationToken()).Wait();   // DownloadVideo.cs:23
chatDownloader.DownloadAsync(CancellationToken.None).Wait();     // DownloadChat.cs:21
```

There is no `CancelKeyPress` or signal handler anywhere in the CLI project.
The only way to stop a step is to kill the process, and its `finally` blocks
will not run.

**Consequence:** we cannot rely on the CLI to clean up after itself. We must own
the temp directory.

### 1.5 Failures escape rather than being reported

`Main` returns `void`, so nothing sets an exit code. A bad VOD id produces:

```
EXIT CODE: 134                       (SIGABRT — .NET aborting on unhandled exception)
stdout: [STATUS] - Fetching Video Info [1/4]
stderr: Unhandled exception. System.AggregateException: ... (Invalid VOD, deleted/expired VOD possibly?)
          ---> System.NullReferenceException: Invalid VOD, deleted/expired VOD possibly?
          at TwitchDownloaderCore.VideoDownloader.DownloadAsyncImpl(...) in /Users/...
```

**Consequence:** a step succeeded iff its expected artifact exists and is
non-empty. Exit codes corroborate; they do not decide.

### 1.6 Options whose value starts with `-` need the equals form

```
--output-args '-c:v h264_videotoolbox ...'    ->  ERROR(S): Option 'c' is unknown.
--output-args=-c:v h264_videotoolbox ...      ->  works
```

CommandLineParser treats a following token beginning with `-` as a new option.
**The argument builder must emit `--opt=value` for any value starting with `-`.**

### 1.7 `--banner=false` is per-verb

It is an option on each verb, not a global. It must follow the verb.

---

## 2. State model

```swift
struct Job: Identifiable, Codable, Sendable {
    let id: JobID
    let created: Date
    let title: String        // "LeighXP — indie horror + something else later??"
    var steps: [Step]        // ordered; index order IS execution order
}

struct Step: Identifiable, Codable, Sendable {
    let id: StepID
    let kind: StepKind
    var status: StepStatus
    var progress: StepProgress
    let dependsOn: [StepID]  // the steps whose artifacts this consumes, in order
    var artifact: URL?
}

enum StepStatus: Codable, Sendable {
    case queued
    case blocked
    case running
    case done
    case failed(StepFailure)
    case cancelled
}

enum StepKind: Codable, Sendable {
    case downloadVideo(VideoRequest)
    case downloadClip(ClipRequest)
    case downloadChat(ChatRequest)
    case renderChat(RenderRequest)
}
```

### Supporting types

```swift
struct JobID: Hashable, Codable, Sendable { let rawValue: UUID }
struct StepID: Hashable, Codable, Sendable { let rawValue: UUID }

/// Everything the UI needs to draw a row. All fields optional because the CLI
/// emits four different status shapes (§1.2) and not all carry every field.
struct StepProgress: Codable, Sendable {
    var phase: String?      // "Downloading", "Rendering Video"
    var fraction: Double?   // 0...1; nil means indeterminate
    var index: Int?         // the 2 in [2/4]
    var total: Int?         // the 4 in [2/4]
    var elapsed: Duration?
    var remaining: Duration?
}

/// What a finished step reports back to the scheduler.
enum StepOutcome: Sendable {
    case succeeded(artifact: URL)
    case failed(StepFailure)
    case cancelled
}

/// One line recovered from the helper's output. The rest of the app sees only
/// this; nothing outside the parser touches raw text.
enum ParsedLine: Sendable {
    case status(StepProgress)
    case log(level: LogLevel, message: String)
    case ffmpeg(String)                          // the `<FFMPEG> ` preamble
}

/// The CLI's log preambles, minus STATUS (which becomes `.status`) and
/// `<FFMPEG> ` (which has no ` - ` separator and becomes `.ffmpeg`).
enum LogLevel: Sendable { case verbose, info, warning, error }

/// A single CLI invocation, fully resolved. Produced by the pure argument
/// builder; consumed by HelperProcess.
struct Launch: Sendable {
    let executable: URL       // Contents/MacOS/helper/TwitchDownloaderCLI
    let arguments: [String]
    let workingDirectory: URL // the step's temp directory
}

/// Engine-internal bookkeeping for a step currently executing. Never persisted.
struct RunningStep {
    let process: HelperProcess
    let task: Task<Void, Never>
}
```

`VideoRequest`, `ClipRequest`, `ChatRequest`, and `RenderRequest` are plain
`Codable` value types holding exactly the user-chosen settings for that verb
(id, quality, trim range, destination, render options). They are defined
alongside the argument builder, since the builder is their only consumer.

Deliberate choices:

- **`dependsOn` is explicit.** In *VOD + chat + render* the render depends on
  step 2, not step 1. Originally at most one parent per step — a forest, never
  a general graph, so no topological sort existed anywhere in the codebase.
  Compositing broke that: a composite step depends on both the finished media
  and the finished render, so `dependsOn` is now `[StepID]` and steps form a
  DAG rather than a forest. No topological sort was added, because none was
  needed — `JobTemplate` is the only place steps get created, and it only ever
  builds acyclic graphs (a composite's parents are steps already appended
  earlier in the same call), so the scheduler's fixed-point walks over
  `dependsOn` still terminate without one.
- **Job status is derived**, never stored. A stored summary can drift from the
  steps it summarises.
- **Resource class is derived** from `kind`: `downloadVideo/Clip/Chat` →
  `.network`, `renderChat`/`.composite` → `.compute`.
- **Interrupted work reuses `.failed(.interrupted)`** rather than earning its own
  case, because it behaves identically to a failure in every respect.

Job templates are a construction-time concern. They expand into steps once; the
runtime model is uniform afterwards.

### v1 templates

| Template | Steps |
|---|---|
| Download VOD | `downloadVideo` |
| Download clip | `downloadClip` |
| Download chat | `downloadChat` |
| Chat + render | `downloadChat`, `renderChat(dependsOn: 1)` |
| VOD + chat + render | `downloadVideo`, `downloadChat`, `renderChat(dependsOn: 2)` |

---

## 3. Scheduler

```swift
enum Scheduler {
    /// Pure: no I/O, no clock, no actor, no processes.
    static func admissible(jobs: [Job], running: Set<StepID>) -> [StepID]
    static func complete(_ step: StepID, with: StepOutcome, in jobs: inout [Job])
    static func retry(_ step: StepID, in jobs: inout [Job])
    static func cancel(_ step: StepID, in jobs: inout [Job])
    static func cancel(job: JobID, in jobs: inout [Job])
}
```

**Admission, in order:**

1. Eligible: status is `.queued` and every step in `dependsOn` is `.done`
   (vacuously true when `dependsOn` is empty)
2. Capacity: at most one running step per resource class
3. Tie-break: job `created`, then step index — deterministic and FIFO

**One drive point.** `actor QueueEngine` holds `jobs` and `[StepID: RunningStep]`.
Every mutation ends by calling `tick()`, which admits and launches. Nothing else
starts work.

**This is not event sourcing.** There is no event type, no log, no replay, no
`Effect` value. Mutations are pure functions over `inout [Job]` solely for
testability; the actor performs side effects directly and we persist *state*,
not history.

**Observation is one-way.** The engine publishes `[Job]` snapshots over an
`AsyncStream`; a `@MainActor @Observable` view model replaces its array
wholesale. Progress is coalesced to ~10 Hz before publishing — §1.1 shows a
single render emitting 401 updates, and each publish is a full snapshot.

---

## 4. Process wrapper

```swift
actor HelperProcess {
    func run(_ launch: Launch, onOutput: @Sendable (ParsedLine) -> Void) async throws -> Int32
    func cancel() async
}
```

**`posix_spawn`, not Foundation `Process`.** `Process` places the child in *our*
process group, so `kill(-pgid, …)` would kill Oxbow. We need
`POSIX_SPAWN_SETPGROUP` with `posix_spawnattr_setpgroup(&attr, 0)` so the helper
becomes its own group leader — then one signal reaches the helper *and* the
FFmpeg it spawned. Without this, cancelling orphans an FFmpeg that keeps writing
into a directory we consider abandoned (`docs/architecture.md` §3.4).

**Cancellation:** SIGTERM to the group, 2s grace, SIGKILL, then `rm -rf` the
step's temp directory unconditionally. Per §1.4 the helper has no signal handler,
so the grace period exists only for FFmpeg, which closes its output on SIGTERM.
The `rm -rf` is what guarantees correctness.

**`WIFSIGNALED` vs `WIFEXITED`** distinguishes our kill from a crash exactly,
which Foundation's `Process` blurs.

**Argument construction is a pure function** and the single place the standing
rules are enforced: `--banner=false` after the verb (§1.7), `--ffmpeg-path`
always explicit, `--output-args=` equals-form with `h264_videotoolbox` and never
`libx264` (§1.6, `docs/ffmpeg.md` §3).

**The parser is one file** and the only code that knows the text protocol, so
`--progress-format json` would be a single-file change if upstream ever ships it.

---

## 5. Persistence

**Temp layout — per job, not per step**, because chained steps hand artifacts
to each other:

```
~/Library/Caches/<bundle-id>/jobs/<jobID>/
    step-<stepID>/     ← --temp-path for that step's part cache
    artifacts/         ← intermediates handed between steps
```

Step subdirectories are deleted when the step ends. The job workspace is
deleted when the job reaches `.done` — clearing the artifact claim of any
`.done` step that pointed inside it in the same operation — and is otherwise
kept for as long as a `.done` step in a `.failed` or `.cancelled` job still
claims an artifact there, so a later retry has its input intact.

**Queue file:** the whole `[Job]` array as JSON at
`Application Support/Oxbow/queue.json`, debounced ~500 ms, written via temp file
plus `replaceItemAt` so a crash mid-write cannot truncate the queue.

**Launch sequence:**

1. Delete the entire `jobs/` temp root unconditionally — nothing in it can be
   reused (§1.3), so there is no case to reason about and no way to leak disk.
   Only `jobs/`: the rest of `~/Library/Caches/<bundle-id>` is not ours to
   sweep.
2. **Skip any job that already reached `.done`.** It is finished, and its
   intermediates were deleted on purpose when it finished; requeueing one of
   its steps would un-finish a job the user has been shown as complete and
   re-download a file that is only discarded again. This exception is
   deliberately narrow — a `.failed` or `.cancelled` job is still retryable,
   and a retry must re-fetch a vanished intermediate rather than run against a
   path pointing at nothing.

   **Known defect, deliberately deferred:** narrowing the exemption to `.done`
   has a cost this design does not yet close. A `.failed` or `.cancelled` job
   whose intermediate was swept still has that step requeued at launch.
   Because `Scheduler.admissible` reads only step status and dependencies —
   never job status — the trailing `tick()` in `start()` then launches it
   unprompted. So a cancelled chat+render job re-downloads its chat on every
   launch, visibly resuming work the user explicitly stopped, and there is no
   job-removal API to escape it. The fix is to make `Scheduler.admissible`
   skip steps belonging to a job that is not runnable; it is deferred, not
   accepted, because nothing consumes this package yet.
3. Reconcile each remaining step:
   - `.running` → `.failed(.interrupted)`
   - `.done` → stays `.done` **iff `artifact` still exists and is non-empty**
     (§1.5), else `.queued`
   - everything else keeps its persisted status

That artifact check is what stops a completed 4 GB VOD download being redone
because a later render failed, while correctly re-running a chat download whose
JSON only ever lived in the workspace.

**Deleting a job workspace is not free.** `artifacts/` holds the intermediates
handed between steps, so a step may be `.done` only while the artifact it
records still exists. A job that reached `.done` may have its workspace deleted,
with the claims on anything inside it cleared in the same breath; any other job
keeps its workspace for as long as a `.done` step records an artifact in it,
because a retry of a later step needs exactly that file.

**Schema:** a top-level `version` integer, read on its own before the payload is
decoded — a future schema that changes `Job`'s shape must reach the version
check rather than failing inside it. An unrecognised version *or any other
decode failure* moves the file aside as `queue.json.bak` and starts empty:
launch must never be blocked by a file the user cannot reach.

---

## 6. Error handling

```swift
struct StepFailure: Codable, Sendable {
    enum Kind: Codable, Sendable {
        case interrupted
        case launchFailed(String)
        case exited(code: Int32)
        case signalled(Int32)
        case noArtifact
        case moveFailed(String)
    }
    let kind: Kind
    let summary: String   // one sentence, shown in the row
    let detail: String?   // full stderr, behind a disclosure, copyable
}
```

**Success criterion is the artifact** (§1.5), not the exit code.

**Stack traces never reach the UI.** Extract the innermost `---> Type: message`,
falling back to the first stderr line. Keep the full trace behind a disclosure
with a copy button.

**Known failures get real messages:**

| Upstream text | Shown |
|---|---|
| `Invalid VOD, deleted/expired VOD possibly?` | This VOD no longer exists or has expired. |
| `vod_manifest_restricted` / `unauthorized_entitlements` | This is a subscriber-only VOD. |
| anything else | the extracted sentence verbatim |

The subscriber-only case is the most common real-world failure for a Twitch
downloader and must not surface as a `NullReferenceException`.

**No automatic retry in v1.** The CLI already retries parts internally and
re-runs FFmpeg once. Manual retry is always available; classification exists so
we do not invite retrying something that can never succeed.

---

## 7. Testing

Swift Testing (`@Test`/`#expect`). Three of four layers need no subprocess.

**Scheduler** — table-driven over literal `[Job]` values: a failed chat download
blocks its render but not an independent VOD download; two downloads never
overlap but a download and a render do; retry requeues *and* unblocks
dependents; tie-break order is deterministic.

**Argument construction** — golden tests asserting `--banner=false` follows the
verb, `--ffmpeg-path` is always present, `--output-args` uses the equals form,
and no render ever emits `libx264`. That last is a permanent regression guard
against a GPL encoder reappearing.

**Parser** — replays `Tests/Fixtures/cli-output/*` at arbitrary chunk
boundaries, proving the incremental parser survives a split landing mid-token.
`chatrender-success.stdout` (401 `\r`, 4 `\n`) is the important case.

**Process wrapper** — a fixture executable that emits known `\r` output, exits
with a chosen code, and spawns a child that outlives it. The test cancels and
asserts **both** PIDs are gone: a direct automated test for the orphaned-FFmpeg
bug.

**Reconciliation** — artifact-existence injected as a closure, so no filesystem.

**Not tested:** SwiftUI views, and anything needing a mocked `Process`. If a test
wants a mock process, the logic belongs in the pure layer.

**CI** runs everything except the real helper. Network-dependent end-to-end runs
are tagged and manual — they fail for reasons unrelated to our code.

**TDD order:** parser (fixtures exist today), then scheduler, then wrapper.

---

## 8. Out of scope for v1

Auto-retry; cache management UI; resume; queue priorities or reordering;
multi-window sync; notifications; the mass downloader.

## 9. Upstream PR candidates

Three tight, independently useful diffs, all of which benefit every consumer of
the CLI rather than just Oxbow (`docs/architecture.md` §8 — address ScrubN):

1. `--progress-format json` — machine-readable progress, replaces `\r` scraping
2. Deterministic cache directory (`{id}_{quality}` not `{id}_{ticks}`) — enables
   resume for everyone
3. Wire `Console.CancelKeyPress` to a real `CancellationTokenSource` — enables
   graceful cancellation

## 10. Open questions

- **Where do intermediates go when the user wants to keep them?** If a user asks
  to keep the chat JSON from a *chat + render* job, it moves to their chosen
  destination and the render reads it from there; otherwise it stays in the job
  workspace. The UI affordance for that choice is a forms question, not a queue
  question, but the queue must support both.
- **Concurrency of `.network` steps against Twitch rate limits** is untested. One
  at a time is the design; whether that is even close to a limit is unknown.
