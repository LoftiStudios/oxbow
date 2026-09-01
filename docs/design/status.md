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
running now, a white badge counting outstanding jobs, and a red `!` when
something has failed.

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
of pixels differ, clustered entirely on our icon: the marker stripe accounts
for the band at y≈200, and the remainder is a scale difference — the probe drew
into full `bounds` while the system insets the icon within the tile. See §5.1,
where that inset stops being an error and becomes a budget.

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
| **any job failed** | **red `!`, overriding the count** |

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

### 5.1 The inset is the badge's budget

The system draws the app icon **inset** within the dock tile — the scale
difference §2.3 measured. That inset is not padding to be reclaimed; it is the
room the badge needs to overflow the icon's corner the way Apple's own
`badgeLabel` does.

Draw the icon at the system's inset and the badge lands where the platform puts
badges. Draw it into full `bounds`, as the probe did, and either the badge is
clipped or it sits inside the icon and reads as a sticker.

### 5.2 Measure Apple's badge, do not guess at it

Badge geometry — diameter relative to icon width, corner inset, cap height,
font weight — has no published metric, because the badge is system-drawn.

**Measure it the same way §2.3 measured the icon**: set a `badgeLabel` on a
control build, screenshot the tile at several dock sizes, and match the
numbers. Then diverge on colour only.

Geometry is what makes a badge read as native; colour is where our meaning
lives. Guessing at the geometry is the one part of this feature that would look
subtly wrong in a way nobody could name and everybody would feel.

**Everything scales off the tile's actual bounds**, never a constant. Dock icon
size is a user preference with real range. A bar height that is right at one
size is a fat stripe at another and a hairline at a third.

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
A white count and a red `!` are both out of reach.

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
