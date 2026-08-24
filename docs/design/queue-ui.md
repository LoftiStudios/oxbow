# Queue UI — design

**Status:** approved 2026-08-24, not yet implemented.

The first application code in the repo. `docs/design/task-queue.md` designed the
engine this draws; that document is the prerequisite for this one.

This slice is deliberately end-to-end: a real `QueueEngine`, a real download, a
real file landing on disk. The forms are still deferred, but a queue with
nothing in it proves nothing, so it ships with the smallest intake that can
produce a real job.

---

## 1. What this slice delivers

Paste a Twitch VOD URL, choose where the file goes, watch it download in a
queue, cancel or retry it, find the finished file at the chosen path.

Explicitly **not** here: clip / chat / render intake, per-job detail views,
settings, notifications, queue reordering, the About box.

## 2. Composition and lifetime

`OxbowApp` builds the engine once at launch, through an `AppComposition` type
that resolves three paths:

| What | Where |
|---|---|
| Helper | `Bundle.main.executableURL/../helper/TwitchDownloaderCLI` |
| FFmpeg | `Bundle.main.executableURL/../ffmpeg` |
| Workspace + store | `~/Library/Application Support/studio.lofti.Oxbow/` |

The first two resolve to `Contents/MacOS/`, which is where
`scripts/embed-helpers.sh` puts them and the only bundle location where
executable code is legal (`docs/signing.md` §2).

Application Support, **never** a path inside the bundle. A quarantined app
launched from `~/Downloads` runs from a read-only App Translocation mount;
`docs/signing.md` §6 verified this. Anything writing next to the app would
fail on first launch for most users.

`AppComposition` returns `.ready(QueueEngine)` or `.helperMissing`. The second
case is not defensive programming — `embed-helpers.sh` deliberately warns and
continues when `build/helper` is absent, so that contributors doing UI work
need no .NET or FFmpeg toolchain (`CONTRIBUTING.md`, fast path) and CI can
build the app without either. Those builds run; they just cannot download. The
UI owes them a clear explanation rather than a crash or a silent hang.

`engine.start()` runs at launch. It sweeps the workspace unconditionally,
loads the persisted queue, and reconciles it — nothing on disk is ever
resumable, by design.

## 3. QueueController

```swift
@MainActor @Observable final class QueueController {
  private(set) var jobs: [Job]
  func start()
  func enqueueVideo(urlText: String, destination: URL) throws
  func cancel(job: JobID) / cancel(step: StepID) / retry(step: StepID)
}
```

One long-lived `Task` consumes `engine.makeSnapshots()` and assigns `jobs`.
Each element is a complete `[Job]` and the stream is `.bufferingNewest(1)`, so
whole-array assignment is both correct and cheap — a chat render publishes one
snapshot per status line, roughly 400 of them, and a superseded snapshot
carries no information.

**Why a controller rather than views observing the stream directly.** It gives
the derived view state a home, and it makes that state testable without a view
host. The alternative scatters progress formatting across views and forces the
engine reference down the hierarchy for actions.

**Why not make `QueueEngine` observable.** It is an `actor`, deliberately off
the main actor, in a library with no UI dependency. The snapshot stream exists
precisely so that observation is somebody else's job.

## 4. View hierarchy

```
QueueView                       single window; toolbar "+"
  List
    JobRow                      one per job
      StepRow                   children, multi-step jobs only
```

`JobRow` shows the title, a status icon derived from `job.status`, and the
representative step's progress. Job status is already derived in OxbowKit and
is never stored — the view layer reads it and does not recompute it.

**Representative step**, defined once so rows never disagree: the first
`.running` step; failing that the first `.failed`; failing that the first
`.queued` or `.blocked`; failing that the last step. This mirrors the
precedence `Job.status` already uses, so the icon and the progress line can
never describe different steps.

Multi-step jobs get a disclosure triangle. Single-step jobs do not: with one
step, the row already shows everything the expansion would.

`StepProgress` has all-optional fields because the CLI emits four different
status line shapes (`task-queue.md` §1.2). A pure `ProgressDisplay` type turns
one into what a row draws — determinate fraction or indeterminate bar, phase
label, `"2 of 4"`, remaining time. Pure, unit-tested, no views involved.

## 5. Intake

Toolbar `+` opens a sheet: a URL field and a destination row.

`TwitchVideoURL` is a pure parser accepting `twitch.tv/videos/123`, the same
with query parameters, and a bare `123`. Everything else is rejected with a
message shown inline in the sheet.

Destination uses `NSSavePanel`, pre-filled with `twitch-<id>.mp4` in
`~/Downloads`. The panel hands back exactly what the engine wants:
`Request.destination` is a **full file URL**, not a directory — `QueueEngine`
creates the parent and moves onto that precise path. The app is not sandboxed,
so no security-scoped bookmarks are involved.

### The `-q` change this requires

`ArgumentBuilder` currently always emits `-q <quality>`, and
`VideoRequest.quality` is a non-optional `String`. A paste-a-URL intake cannot
know the quality before the download begins, and the honest default is "best
available."

So: **an empty `quality` means omit `-q` entirely** and let the CLI choose.
This is a change to OxbowKit, developed test-first alongside the existing
`ArgumentBuilder` tests.

## 6. Error and empty states

- **Empty queue** — a real empty state, not a blank list.
- **`.helperMissing`** — explanatory banner, `+` disabled. Says what is missing
  and which command produces it.
- **Failed step** — `StepFailure`'s message in the expanded step row, with
  retry.

## 7. Testing

`QueueEngine` takes `makeProcess: () -> HelperProcessing`, and OxbowKit's test
suite already has a `FakeHelper`. Controller tests therefore drive a **real
engine** with fake processes: real scheduling, real state transitions, no
subprocesses and no network.

| Unit | Covered by |
|---|---|
| `QueueController` | enqueue produces a job; cancel settles `.cancelled` not `.failed`; snapshots drive `jobs` |
| `TwitchVideoURL` | accepted forms, rejected forms |
| `ProgressDisplay` | each of the four CLI status shapes |
| `ArgumentBuilder` | empty quality omits `-q` |

In the `OxbowTests` target with Swift Testing, matching the existing suite. No
UI snapshot testing.

End-to-end verification uses the short LeighXP VOD the parser fixtures were
captured from, so the manual check stays measured in minutes.

## 8. Open questions

- **Job titles.** This slice titles a job from its video ID, because the real
  title requires a network call the CLI makes but does not report back before
  the download starts. Whether to surface the real title later is a forms
  question.
