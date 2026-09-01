# Status: the Dock and Notification Center

Oxbow is built to be walked away from. An eighty-eight minute composite is the
normal case, not the tail. And for the whole of that eighty-eight minutes the
app says nothing to anyone who is not looking at its window: no dock badge, no
dock progress, no notification when it finishes. The one surface a
walked-away-from app has is the one surface this app does not use.

This document covers all three, because they are one decision about what the
app says about itself, not three features that happen to be near each other.

---

## 1. What this delivers

**A dock tile that carries the queue's state**: a progress bar for the step
running now, a white badge counting outstanding jobs, and the app's own red
warning triangle when something has failed.

**A notification when a job reaches a terminal state**, with an action that
reveals the delivered files.

**What it does not deliver** is a second source of truth. Every value here is
derived from the same `[Job]` snapshot the window draws from, through the same
precedence rules the window already uses. §4.1 is the whole reason that
constraint is written down.

---

## 2. The spike: does a custom dock tile forfeit the macOS 26 icon?

**Resolved: no.** `NSApp.applicationIconImage` returns the appearance-treated
rendering, so a custom content view can draw it and keep the treatment.

This section exists because the question will come back. It is the first thing
anyone asks when they see that we own the dock tile's drawing, and the answer
is not in the documentation.

### 2.1 Why it was in doubt

Setting `NSDockTile.contentView` **replaces the icon**. That has been the
contract since 10.5 — you are not overlaying onto Apple's rendering, you are
substituting for it, and you become responsible for drawing the icon yourself.

What changed in macOS 26 is the value of what you give up. Oxbow ships an Icon
Composer bundle (`Oxbow/Oxbow.icon/`, `ASSETCATALOG_COMPILER_APPICON_NAME =
Oxbow`), and the system composites it with material effects across four
user-selectable appearances — Default, Dark, Clear, Tinted. Taking over the
tile used to cost a static PNG. If it now costs the appearance treatment, then
a dock progress bar is bought at the price of an icon that stops responding to
the user's own settings, in an app whose deployment target was raised to macOS
26 specifically to get that treatment.

The observation that prompted the spike: **Transmission does not honour Clear
in the Dock**, and Transmission is the canonical implementation of exactly this
feature.

### 2.2 The discriminator

Transmission honours Clear **in Finder** and not in the Dock. Same app, same
icon, and the only variable between those two renderings is the dock tile
content view. That isolates the effect to the content view and rules out the
competing explanation — that Transmission simply ships a legacy `.icns` and
gets a poor approximation everywhere.

It does not, however, establish *why*. Transmission is a fifteen-year-old
Objective-C codebase with no reason to have revisited that call site, and the
classic implementation draws a bundled asset — `NSImage(named:)` — rather than
asking the system for the current icon. Which leaves the real question: does
`NSApp.applicationIconImage` hand back the treated rendering, or a flat baked
image?

### 2.3 The probe

A throwaway `NSView` set as `NSApp.dockTile.contentView`, drawing
`NSApp.applicationIconImage` into its bounds, plus a red stripe across the
bottom six points. Control: the same Debug build with the probe call commented
out. macOS 26.6.2 (25G83), `AppleIconAppearanceTheme = ClearDark`.

**The red stripe is the part that makes the result mean anything.** Without a
marker, an icon that looks correctly treated is equally consistent with the
content view having silently failed to install, leaving the system's own icon
on screen and the probe concluding nothing. The stripe proves `draw(_:)` ran.

**Result: the probe icon renders in the same Clear glass material as the
control.** Not the purple opaque icon. Over a 400x250 screen crop at 2x, 2.53%
of pixels differ, clustered entirely on our icon.

**The scale difference this section originally reported was not real, and is
retracted.** The first probe concluded that the remaining pixel difference was
the system insetting the icon within the tile while we drew into full
`bounds`. §5.2's measurement disproved it: with the content view outlining its
own bounds, our icon body and the system's occupy *identical* columns —
`438...507` in a tile spanning `414...531`, in both captures. The apparent
difference came from cropping two captures taken minutes apart at the same
screen coordinates, between which the Dock's contents had shifted, so the two
crops were not of the same region.

The lesson is worth more than the retraction: **a screenshot comparison with no
fiducial in the frame cannot tell a real difference from a misalignment.** The
fix was to make the content view draw its own bounds, so both measurements
share a coordinate system that is visible in the image.

### 2.4 What the probe did not answer

**Only `ClearDark` was tested.** Default, Dark and Tinted are assumed to behave
the same way on the strength of the mechanism — one treated rendering, handed
back by one accessor — but they were not screenshotted. If one of them
misbehaves, this is the paragraph that was too optimistic.

**Whether the tile is told when the user changes appearance mid-run is
unknown.** There may be no notification for it. Rather than answer it, §5.3
structures the presenter so the question cannot arise.

---

## 3. What the badge counts

Two channels, two meanings, and they never overlap:

> **The bar says how far along. The badge says whether it needs you.**

That division is the whole design. The alternative — one number that means
outstanding work most of the time and failures the rest of the time — was
considered and rejected in §8.2, because a badge reading `2` that means two
different things at two different times, with nothing on the icon saying which,
is a badge you have to open the window to interpret. A badge you cannot read is
worse than no badge.

| queue state | badge |
|---|---|
| nothing outstanding | none |
| one job outstanding | none |
| two or more outstanding | white, count of `.queued` + `.running` jobs |
| **any job failed** | **`exclamationmark.triangle.fill` in system red, overriding the count** |

**Failure wears the app's own glyph**, `exclamationmark.triangle.fill` in
system red — the same symbol `JobPresentation.icon(for:)` puts on a failed row,
so the Dock and the window say one thing rather than two dialects of it. The
shape differing from the count's disc is deliberate: a circle answers "how
many" and a triangle says "something is wrong", both legible before either is
read, where two states differing only in colour would need looking at.

**Failure is sticky and wins outright.** It persists until the user retries or
removes the job, which is the only thing that resolves it. It overrides the
count rather than sitting beside it because there is one badge position, and
between "how many" and "something is wrong" the second is the one that wants
action.

**The bar is unaffected by failure.** Jobs 1 and 2 can be running while job 3
has already failed; dropping the bar there would hide live work behind a
failure that is not blocking it.

**The count hides at one.** With a single job the bar already tells the whole
story, and a badge reading `1` adds a glyph without adding information.

### 3.1 Jobs, not steps

The count is jobs, because jobs are what the window's list displays. A badge
counting something the window does not show is a badge that reads as broken.
A single composite job would badge `4` or `5` under a step count, against one
row on screen.

---

## 4. What the bar measures

**The active step's own progress** — not aggregate queue progress.

Whole-queue progress was the first choice and was reversed. It has the better
property in the abstract (monotonic, never jumps backwards) and the worse one
in practice: with several jobs outstanding it crawls, and finishing an entire
download barely moves it. A bar that does not visibly move is a bar nobody
looks at twice.

The cost is accepted and recorded here so it is not rediscovered as a bug:
**the bar resets to zero every time a step finishes**, including between the
steps of a single composite job. Glancing at the Dock tells you how far through
the current piece of work you are, and does not tell you how much work remains.
The badge is what carries the second question.

### 4.1 Which step, when two are running

`ResourceClass` is `.network` and `.compute`, and `Scheduler.admissible` admits
one running step per class — so a download and a render genuinely overlap.
"The active step" is not singular and needs a rule.

**The rule is the window's rule.** Oldest running job, and within it
`JobPresentation.representativeStep(of:)` — literally the step that job's
collapsed row is describing.

This is not a preference. `JobPresentation.representativeStep` exists, and
carries a long comment about mirroring `Job.status`'s precedence tiers,
precisely so a row's icon and its progress line can never describe two
different steps. A second precedence rule written here would be a second
answer to the same question, free to drift from the first. There is one rule;
the Dock uses it.

### 4.2 Indeterminate steps

`StepProgress.fraction` is optional — the CLI emits four status shapes and not
all carry it. When it is absent, **draw the track with no fill.**

Not "hide the bar": an absent bar reads as idle, which is a lie while a chat
download is running. An empty track says *working, no estimate*, which is true.

Not an animated barber-pole either, however much better it would look. It needs
a repaint timer, and that discards the property in §6 where redraw throttling
falls out of `Equatable` for free. A cosmetic gain is not worth reintroducing a
timer whose only job is to fight a mechanism we chose deliberately.

---

## 5. Drawing

### 5.1 The icon is drawn edge to edge, and the badge overlaps it

**There is no icon inset to reproduce.** `NSApp.applicationIconImage` carries
its own padding, so drawing it into the content view's full `bounds` places the
visible icon body exactly where the system places it. Measured: identical
columns, `438...507` inside a tile spanning `414...531`, for our drawing and
the system's alike.

An earlier draft of this section claimed the opposite — that the system insets
the icon, and that the inset was "the badge's budget," the room the badge needs
to overflow the icon's corner. **Both halves were wrong.** There is no inset,
and the badge needs no budget: it simply draws on top of the icon's top-right
corner, which is what Apple's own badge does on every app in the Dock. Look at
any badged icon there and the badge is over the artwork, not beside it.

### 5.2 Measure Apple's badge, do not guess at it

Badge geometry has no published metric, because the badge is system-drawn. So
it was measured, on macOS 26.6.2 (25G83), by installing a content view that
outlines its own bounds and marks deciles along the top and right edges, then
setting `badgeLabel` and letting the system draw over it. One capture then
carries both the badge and the coordinate frame it must be expressed in.

**Measuring against the Dock's icon pitch instead is wrong**, and was the first
attempt. The pitch is the spacing between icon centres; it is not the tile, and
every ratio derived from it is scaled by an unknown factor. The fiducial
removes the guess. (In this configuration they coincidentally agreed at 118px,
which is exactly the sort of accident that would have validated a bad method.)

Results, in the tile's own coordinate space:

| quantity | measured |
|---|---|
| `NSApp.dockTile.size` | **128 x 128 pt, always** — independent of the Dock size preference |
| tile as rendered | 118 x 118 px at the Dock size tested (0.922 px/pt) |
| badge diameter | 46 px = **0.3906 of tile width** = 50 pt of 128 |
| badge centre, from right edge | 24.4 pt |
| badge centre, from top edge | 24.4 pt |

The two centre offsets are equal, and each is one radius. **The badge is
tangent to the top-right corner** — it exactly fills the corner square of side
50 pt. That is the whole geometry, in one number, and it lands on a round
number of points in the 128 pt space, which is a good sign it is the real value
rather than an artefact of the capture.

Geometry is what makes a badge read as native; colour is where our meaning
lives, and colour is the only axis on which we deliberately diverge.

**A consequence worth stating, because it inverts an assumption elsewhere in
this document:** the tile's drawing space is a *fixed* 128 pt square whatever
the user's Dock size, and the system scales the result. Coordinates therefore
never need to adapt. What still does is legibility — at a small Dock size a bar
5% of 128 pt is under two rendered pixels tall, so the bar's proportions are a
design question even though its arithmetic is not.

The bar's own numbers — `barWidth`, `barHeight`, `barBottomInset` — are ours
rather than the platform's, and are chosen, not measured. §11 records where
they ended up after being looked at.

### 5.3 The content view is installed only while there is something to draw

Idle: `NSApp.dockTile.contentView = nil`. The system owns the icon completely,
and appearance changes are its problem, not ours.

Working: install the view and redraw it.

This is what makes §2.4's unanswered question — is the tile notified when the
user changes appearance? — stop mattering. At rest we are not drawing, so there
is nothing to go stale. While working we redraw several times a second anyway,
so any change is picked up within a frame whether or not a notification exists.

The structure is chosen so the question cannot arise. Do not "simplify" this by
installing the content view once at launch and leaving it there.

---

## 6. Redraw: quantization, not debounce

A chat render publishes roughly 400 snapshots. Redrawing the dock tile 400
times is waste, and the obvious fix — a debounce timer — adds a piece of
timing-dependent behaviour that can only be tested by watching the Dock.

Instead: `QueueStatus` is `Equatable`, and its `fraction` is **quantized to the
bar's drawable resolution** before it is stored. Two snapshots that would draw
the same pixels produce equal values, the presenter skips the redraw, and the
throttle becomes a unit test over a pure function rather than a behaviour
nobody can assert on.

Quantization granularity derives from the tile's bar width in pixels, per §5.2.

---

## 7. Notifications

**One notification per job reaching a terminal state.** Not per step: a
composite job would fire five.

| terminal status | notification | action |
|---|---|---|
| `.done` | "Finished — *title*" | reveals `job.deliveredFiles` |
| `.failed` | "Failed — *title*" | activates the app |
| `.cancelled` | **none** | — |

Cancellation is silent because the user did it. Telling someone that the thing
they just cancelled is cancelled is the app talking to itself.

### 7.1 The first snapshot seeds, and notifies nothing

Transitions are detected by diffing successive snapshots, which means the
first snapshot has nothing to diff against.

It **must** establish the baseline silently. `QueueEngine.start()` reconciles
the loaded queue before publishing — a step left `.running` by `shutDown()`
becomes `.failed(.interrupted)` — so the first snapshot after launch routinely
contains freshly-failed jobs. Without seeding, every launch after an
interrupted run fires notifications for something that happened yesterday.

Job removal is not a transition either. A job that disappears from the snapshot
did not finish; it was deleted.

### 7.2 Authorization is requested on first enqueue

Not at first launch: the user has no idea yet what the app does or why it would
want to notify them, and a permission prompt is the worst possible first
impression of a tool they have not used.

Not at first completion: that is the event we would be asking permission to
report, and it is already over.

**On first enqueue** the context answers the question by itself — they have
just started something long, and the ask needs no explanation. It costs a modal
in the middle of the intake flow, which is the trade.

A denial is quiet and permanent. Nothing nags, nothing degrades, and no error
is surfaced — consistent with the update check, which is deliberately silent
about its own failures. A user who says no gets an app that behaves exactly as
it does today.

A pre-prompt of our own (explain, then ask the system, protecting the one-shot)
was considered and dropped. Two dialogues where one will do is ceremony, and
this app does not do ceremony.

---

## 8. Rejected

### 8.1 `NSApp.dockTile.badgeLabel`

The obvious implementation, and it cannot express this design. `badgeLabel` is
a red pill containing a string: no bar, no second element, no colour control.
A white count and a red warning triangle are both out of reach.

More to the point, **it does not avoid the content view**. There is no way to
draw a progress bar on a dock icon without one, so the appearance-treatment
question of §2 arrives whichever badge mechanism is chosen. `badgeLabel` buys
nothing and costs the design.

### 8.2 A badge that switches meaning

Count while work is in flight, failure count once the queue drains. Rejected in
§3: `2` would mean two different things at two different times.

A variant — count, then `!` on drain — is unambiguous but hides a failure for
as long as the queue keeps running, which can be hours. Sticky-and-wins is
strictly more useful and no harder to draw.

### 8.3 Aggregate queue progress

See §4. Better in the abstract, worse to look at.

### 8.4 Two bars, one per resource class

Literally what the scheduler models, and closest to Transmission's up/down
pair. Two thin bars are unreadable at small dock sizes, and most jobs occupy
one class at a time regardless.

---

## 9. Shape

`Oxbow/Status/`, alongside `Oxbow/Update/` and `Oxbow/About/`.

| type | isolation | responsibility |
|---|---|---|
| `QueueStatus` | `nonisolated struct` | the whole derivation from `[Job]`: badge, quantized fraction |
| `NotificationDecision` | `nonisolated enum` | diffs two snapshots into terminal transitions |
| `DockTileView` | `NSView` | draws a `QueueStatus`. Knows nothing else |
| `DockPresenter` | `@MainActor` | observes snapshots, installs or clears the content view |
| `JobNotifier` | `@MainActor` | authorization, delivery, and the reveal action |

The two pure types carry every decision; the two `@MainActor` types carry
plumbing and no rules. That split is what makes the rules testable.

### 9.1 Snapshots are trustworthy; the persisted queue is not

An earlier note held that the badge should key off `QueueEngine.running`
rather than step status, because `shutDown()` deliberately leaves steps
`.running` so the reconciler can call them interrupted.

**That is true of the persisted queue and false of published snapshots.**
`QueueEngine.jobs` has exactly one whole-array assignment — `jobs =
Reconciler.reconcile(loaded)` in `start()` — and every other mutation is
element-level. `publish()` yields nothing but `jobs`. So the loaded-but-
unreconciled queue is never a value the array holds, and an unreconciled
snapshot cannot reach the UI. In a snapshot, `.running` means running.

This matters because it is the difference between a pure function of `[Job]` —
testable, no actor hop, same input the window already has — and reaching into
the engine for a second answer to a question the snapshot already answers.

### 9.2 The `isUserSession` trap

`OxbowTests` runs **inside** the app, so `xcodebuild test` launches `OxbowApp`
for real: scenes, `.task` modifiers, and anything the launch path touches.
That is why `AppComposition.isUserSession` exists — the automatic update check
was performing a live request to api.github.com on every test run, on every
machine and every CI run, and went unnoticed because it is silent about its own
errors by design.

**A notification authorization prompt is strictly worse than a stray HTTP
request: it is a modal that hangs CI.**

Both `DockPresenter` and `JobNotifier` are gated on
`AppComposition.isUserSession`, with a test asserting the gate.

### 9.3 What is tested, and what is not

`QueueStatus` and `NotificationDecision` are pure and table-tested in
`OxbowTests`, where `JobPresentation` and `ProgressDisplay` already live.
Cases that matter: the count hiding at one, failure overriding the count,
failure not suppressing the bar, the representative-step rule under two
concurrent steps, indeterminate steps, quantization boundaries, the seeding
snapshot notifying nothing, and cancellation staying silent.

The drawing and the `UNUserNotificationCenter` plumbing are verified by hand,
consistent with the rest of the app layer.

**These live in `Oxbow/`, not `Sources/OxbowKit/`, so they do not count toward
the 90% coverage floor.** That follows `JobPresentation`'s precedent:
presentation rules live in the app and are tested by `OxbowTests`. Moving
`QueueStatus` into OxbowKit to buy floor coverage would put a Dock concept in a
library that deliberately has no UI dependency, which is a worse trade than the
coverage is worth.

---

## 10. Not in scope

- **Dock menu items** (pause the queue, recent jobs). Separate feature, no
  shared machinery beyond the snapshot.
- **Notification actions beyond reveal** — retry from the notification, in
  particular. It wants the engine reachable from a notification response, which
  is a lifecycle question this document does not need to answer.
- **A Settings toggle for any of it.** There is no `Settings` scene and no
  `@AppStorage` anywhere yet. When that lands, notifications are an obvious
  first inhabitant; building half a preferences system here to hold one
  checkbox is not.

---

## 11. What has been verified, and what has not

Recorded because `docs/twitch-metadata.md` §7 is this project's standing
argument that an exit code is not verification — and "it looked right" is a
weaker claim still. This section is the honest boundary of what anyone has
actually seen.

macOS 26.6.2 (25G83), Dock size as configured on the development machine
(tile rendered 118px), `AppleIconAppearanceTheme = RegularDark`.

**Exercised against a real job, by hand:**

- The observers attach and receive every snapshot. Confirmed by instrumenting
  the path, not by reading it — see §11.1.
- The bar advances through a running step, 0 to ~1, and resets when the next
  step of the same job starts. That reset is the accepted cost of §4's choice
  and is working as designed, not a defect.
- `.indeterminate` renders as a track with no fill, on a step carrying no
  fraction.
- The alert badge appears when a job fails.
- The badge geometry, drawing, and colours (§5), reviewed on rendered tiles at
  256pt.

**Not yet verified by anyone:**

- **The count badge.** Every observed run had at most one outstanding job, so
  a white disc with a number in it has never appeared outside an offscreen
  render.
- **The idle handoff** — that clearing `contentView` returns the icon to the
  system, and that the user's icon appearance setting then applies. This is
  §5.3's whole justification.
- **The icon under Clear or Tinted on the live dock tile while a job runs.**
  Partly closed: `DockTileView` was rendered offscreen with the system set to
  `ClearDark` and drew the glass treatment, not a baked image — so the drawing
  path does get the treated icon. What that does not cover is the live tile:
  how it composites in the Dock, and whether it picks up an appearance change
  made mid-job. Tinted is still untested entirely.
- **Every notification behaviour**: the authorization prompt on first enqueue,
  a banner while Oxbow is in the background, the chime in both cases with the
  banner suppressed while Oxbow is frontmost, and Show in Finder revealing the
  delivered file. The chime in particular — `UNNotificationSound` falls back
  to the system sound rather than failing when it cannot resolve a file, so
  "a sound played" is not evidence that *our* sound played.
- **Silent seeding (§7.1)** — quit with a job running, relaunch, and confirm
  the reconciler's `.failed(.interrupted)` fires no notification. This is the
  single most likely thing here to be wrong, because it is the one behaviour
  whose correct outcome is *nothing happening*.

### 11.1 The bug this section exists to remember

The dock tile never updated at all on the first hand-run, and the cause was
ordering: `attachStatusObservers(to:)` is called from the scene's `.task`,
while the observers were built in `applicationDidFinishLaunching`. **SwiftUI
runs `.task` first.** The attach found both observers `nil`, took its early
return, and wired nothing.

Two lessons worth more than the fix:

- **It failed into silence.** An optional that is `nil`, a guard that returns,
  and no surface anywhere saying so. A feature that cannot work looked
  identical to a queue with nothing to report.
- **Reading the code did not find it, twice.** The order was asserted from
  memory of the lifecycle and was backwards. One instrumented launch settled
  it. When a question is about *when* something runs, instrument it — the
  answer is not in the source.

The observers are `lazy` now, so neither call site depends on arriving first.
