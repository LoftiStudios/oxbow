# One action, and the two entry points it replaces

Oxbow has no way in from outside itself. Every download begins by switching to
the app. The clipboard hand-off and the defaults that landed in 0.4.0 made
everything *after* that switch nearly free — paste and go — which leaves the
switch as the whole remaining cost, and no feature inside the window can
remove it.

This document covers a single App Intent, `DownloadTwitchVideoIntent`, and
records why the two features that sat beside it in `docs/development.md` —
drag-and-drop and an `oxbow://` URL scheme — are not being built. It also
records the one piece of architecture the intent forces, which is not the job
composition anyone would expect but the app's own launch sequence.

---

## 1. What this delivers

**One Shortcuts action, `Download Twitch Video`.** It takes a link and four
optional overrides, resolves everything else from `Preferences`, enqueues, and
returns without opening a window.

**A Spotlight action, for free.** macOS 26 surfaces third-party App Intents in
Spotlight automatically. ⌘Space, the action, paste, Return — a job is queued
without Oxbow ever coming forward. This is the reason to build it. Shortcuts
is the secondary audience; Spotlight is every user.

**Batch, as a consequence rather than a feature.** Shortcuts runs an action
once per item in a list, so `Repeat with Each` over twelve links is twelve
jobs. Multi-link intake — cut from v1 in `task-queue.md` §8 and still on the
backlog — arrives here without being built.

**What it does not deliver** is a way to wait for a download. See §9.

---

## 2. The friction this removes, and the friction it does not

The honest measurement, because it decides how much this is worth:

| Today | With the intent |
|---|---|
| ⌘Tab or Dock click | ⌘Space |
| ⌘N | type "download" |
| (clipboard prefills) | ⌥⌘V |
| wait for metadata | Return |
| Return | |

That is one app switch and perhaps two seconds. **It is an incremental
improvement to an already-cheap flow, and it should not be described as
anything more.** The reason to build it anyway is that it is genuinely small
(§4), it opens a system-wide entry point rather than a deeper one inside a
window, and it is a differentiator worth writing about — nothing else in this
space on the Mac has it.

What it does not remove is the reason someone forgets to download a VOD at
all. VODs expire after 14 days, or 60 for partners, and a missed one is gone.
No entry point solves that; a channel watcher would. That is a different
project and is deliberately not this one.

---

## 3. The action

### 3.1 Parameters

| Parameter | Type | Required | Default |
|---|---|---|---|
| Link | `String` | yes | — |
| Quality | `QualityCap` | no | `Preferences.qualityCap` |
| Include Chat | `DownloadOutput` | no | `Preferences.output` |
| Chat Size | `ChatSize` | no | `Preferences.chatSize` |
| Destination | `URL` (folder) | no | `Preferences.destination` |

**Every override defaults to the stored preference, never to a factory
value.** An omitted parameter must mean "whatever the Settings window says",
not "best available to ~/Downloads" — otherwise the action and the app
disagree about what the user asked for, and the action is the one nobody is
watching.

The link is a `String`, not a `URL`. `TwitchLink.parse` already accepts a bare
VOD id, a bare clip slug, and a scheme-less host, and a `URL` parameter would
reject the first two before Oxbow ever saw them.

### 3.2 The vocabulary already exists

`QualityCap`, `DownloadOutput` and `ChatSize` are `String`-backed,
`CaseIterable`, and carry a `label`. That is exactly an `AppEnum`, so each
conformance is a `typeDisplayRepresentation` and a `caseDisplayRepresentations`
dictionary over values that already exist.

This is not a coincidence worth passing over. `settings.md` §3.1 refused to
store a rendition name because rendition names are per-video and unstable —
`1080p60`, `720p0-1`, `1080p60-Portrait-1` — and stored a policy instead. A
per-video name could not have been an intent parameter at all; a policy can.
The ladder built for the Settings window is what makes an automatable quality
parameter possible, and `QualityLadder.resolve` is what turns the policy back
into this video's rendition with no human present.

**`QualityCap`'s raw values are already pinned by
`QualityLadderTests.rawValuesArePersistedAndPinned`.** Adding `AppEnum` gives
them a second reason not to change: an `AppEnum` case identifier is what
Shortcuts persists inside a user's saved shortcut, so renaming one silently
breaks shortcuts that already exist, off in a file this repository cannot see.
That test's failure message should say so.

### 3.3 The parameter summary keeps Spotlight to one line

`ParameterSummary` puts `\.$link` in the summary and leaves the four overrides
in the "Show More" section. Spotlight then shows `Download Twitch Video [link]`
rather than five fields, and Shortcuts users who want the overrides expand
them. Optional parameters cost the common case nothing.

### 3.4 What it returns

`JobID`, as an `IntentResult` with a dialog naming the job — "Queued *Streamer
— 2026-08-14 — Title*". The id is returned so a later action can refer to the
job; the dialog is what Spotlight actually shows, and it is the only
confirmation a user who never opens the app will get.

---

## 4. Composition is not the problem

The expected shape of this work was extracting a headless job composer out of
`IntakeModel` so that both the window and the intent could build a
`JobTemplate`. **That extraction is not being done, because it is not needed.**

`IntakeModel` already has no window in it. Its own opening comment says the
rules live there so they can be tested without one; `fetchInfo`, `enqueue`,
`fileExists`, `volumeSpace` and `preferences` are all injected;
`init(controller:)` seeds the four standing preferences; `load()` awaits the
metadata fetch, resolves the cap against the video's real renditions, and
derives the output name; `add()` awaits the enqueue all the way into the
engine and returns whether it landed. The intent's core is therefore:

```swift
let model = IntakeModel(controller: controller)
model.linkText = link
if let quality { model.qualityCap = quality }
if let output { model.output = output }
if let chatSize { model.chatSize = chatSize }
if let destination { model.folder = destination }
await model.load()
guard await model.add() else { throw Error.refused(model.addFailure) }
```

An intent is another headless driver of a model that was built for headless
drivers. Extracting a `JobComposer` into `OxbowKit` to serve a second caller
that the existing type already serves would churn 2,142 lines of
`IntakeModelTests` to arrive where the code already is. If a third caller
turns up and the reuse hurts, extract then — the tests that would justify it
are the ones that would have to move anyway.

**One ordering constraint.** The overrides are applied *before* `load()`,
because `load()` reads `output` to decide whether resolution must skip a
rendition a composite cannot use (`settings.md` §3.4) and reads `qualityCap`
to pick the rendition at all. Applying them afterwards would resolve the
quality against the wrong policy and leave `quality` naming a rendition the
override did not ask for.

**The intent must not save defaults.** `saveDefaultsIfRequested()` is driven by
the intake's checkbox, which the intent never sets. An override passed to one
Shortcut run is a decision about that run, not a standing preference —
`settings.md` §2.2 refuses last-used-wins for the window, and an automation
that silently rewrites the user's defaults would be a worse version of the same
mistake.

---

## 5. The launch sequence is the actual work

An App Intent can run with Oxbow **not running at all**: the system launches the
app to execute it. Everything the intent needs is behind a `QueueController`
that does not exist yet at that moment, and there is currently no way to wait
for one.

Worse than a race. `setUp()` runs from the queue scene's `.task`, so it is the
*window appearing* that builds the engine. An intent that deliberately does not
show a window would therefore wait for a controller nothing is constructing —
not slow, but permanently hung.

**The fix is to stop making engine construction a side effect of a view
appearing.** A `@MainActor` `QueueHost` owns the resolution `setUp()` does
today, idempotently, and hands out the result:

```swift
@MainActor final class QueueHost {
  static let shared = QueueHost()
  func ready() async -> QueueContent   // resolves once; later callers get the same answer
}
```

Both the scene's `.task` and the intent call `ready()`. Whichever arrives first
does the work and the other awaits the same outcome.

**This removes an ordering assumption rather than moving it**, which is the
same reasoning `AppDelegate`'s `lazy dock` and `lazy notifier` already record:
those were built in `applicationDidFinishLaunching` on the assumption that it
precedes the scene's `.task`, it does not, and the fix was to stop depending on
which came first. This is that fix applied one level up, to the thing those
two observe.

**A singleton, deliberately.** The app is single-engine by construction — the
long comment on the `Window` scene in `OxbowApp` explains what a second
`QueueEngine` over the same `queue.json` and workspace would destroy. A shared
instance that *matches* an invariant the app already enforces is honest; the
alternative is threading a controller into a type App Intents constructs for
us, which cannot be done.

**`helperMissing` must fail the intent, not hang it.** `ready()` returns
`QueueContent`, not `QueueController?`, so the unavailable case carries its
message and the intent throws it. A bounded wait guards the remaining case
where resolution neither succeeds nor fails.

**`attachStatusObservers` moves to the host**, since it must happen before
`start()` regardless of which caller triggered it.

---

## 6. No window, and what that costs

`openAppWhenRun = false`. The app launches in the background, enqueues, and
stays running because it has a queue to work — which is correct for a
downloader and is what the Dock badge and the completion notification from
0.4.0 are already for.

Two consequences worth stating rather than discovering:

**Oxbow appears in the Dock.** It is a regular app, not an agent, so a
background launch still shows a Dock icon. That is acceptable and arguably
right: the badge and tile progress are how a user who never opened a window
sees that something is happening.

**The first enqueue can raise a notification-permission prompt with no window
behind it.** `QueueController.onEnqueue` calls
`JobNotifier.requestAuthorizationIfNeeded()`, and the first time that fires
from an intent there is nothing on screen to explain it. `status.md` §7.2
already treats the timing of that prompt as a design decision; this adds a case
it did not consider. **Unresolved.** The options are to suppress the request on
an intent-driven enqueue, or to accept it — a system prompt naming Oxbow is not
mysterious, merely abrupt. Decide before shipping; do not let it ship
unnoticed.

---

## 7. Refusals have to be readable in one line

Every refusal `IntakeModel` can produce was written for a form with room under
it: `addFailure`, `chatProblem`, `compositeProblem`, and the disk
`SpaceWarning` with its remedy. Spotlight shows a sentence.

The intent throws a localized error carrying whichever refusal applies, in the
model's own words where they survive compression and in a shorter form where
they do not. **Two need rewording**: `chatProblem` and `compositeProblem` both
end in an instruction to change a control the intent has no equivalent of
("Choose \"Video\"", "Pick another quality"). From an intent those become the
parameter names — `Include Chat` and `Quality`.

The disk warning is a special case. In the window it is a warning with a
remedy, and Add stays enabled. From an intent nobody is reading it, so the
enqueue proceeds and the warning is dropped: refusing a job the window would
have allowed makes the two disagree, which is worse than a job that runs out of
room in the way the window already permits.

---

## 8. Shape

**`QueueHost` and the intent live in the app target**, alongside `IntakeModel`
which they drive. Nothing here belongs in `OxbowKit`: the intent is an entry
point, and the host owns a lifecycle the library has no opinion about.

**The `AppEnum` conformances live beside the enums' own types in `OxbowKit`.**
`AppIntents` is a system framework with no deployment cost, and splitting a
type's display names away from the type is how they drift.

### 8.1 What is tested

`QueueHost` resolution: that two concurrent `ready()` callers resolve once and
receive the same outcome, that `helperMissing` is delivered rather than
awaited, and that a caller arriving after resolution gets the answer without
re-resolving.

The intent's parameter handling, driven against an `IntakeModel` built with
stub collaborators: that omitted parameters take stored preferences, that
overrides are applied before `load()` and therefore change which rendition
resolves, that a refusal becomes a thrown error carrying the model's reason,
and that no preference is written on any path.

**Not tested: that Spotlight and Shortcuts actually show the action.** That
needs the built, installed app and a look at the two front ends. It is the same
kind of hand-verification the menu icons in `settings.md` §7 needed, and for
the same reason: nothing in a test bundle can see it.

---

## 9. Not in scope

- **Waiting for a download to finish.** A composite can run six hours; a
  Shortcuts action cannot block on one, and macOS offers third-party apps no
  "download finished" automation trigger. The intent enqueues and returns; the
  notification tells the human. An action that returned the finished file
  would be the natural request and cannot be built.
- **Trim.** Two timecodes on an action nobody is watching, guarding a
  bounds check whose failure the window explains and an intent cannot. The
  intake keeps it.
- **A name parameter.** Names come from metadata by design (§4 of the queue
  design doc); overriding one per automation run is a per-link preference,
  which `settings.md` §9 already places out of scope.
- **Querying or controlling the queue from Shortcuts** — pausing, cancelling,
  listing jobs. Worth considering once the submit action has users; speculative
  before that.
- **Channel watching.** Its own project. See §10.4.

---

## 10. Rejected

### 10.1 Drag-and-drop

Dropping a link on the queue window saves nothing: the window already fills its
link field from the clipboard when it opens, so the drop replaces a paste that
does not happen. Dropping on the Dock icon is worth marginally more because it
works while the app is closed — but that is the case the intent covers
properly, with parameters and an error surface a Dock tile does not have.

Not opposed on principle; it is simply the third-best answer to a question the
other two answer better, and every hour spent on it is an hour not spent where
§2 says the real gap is.

### 10.2 The `oxbow://` URL scheme

**Nothing on a Mac produces `oxbow://` URLs.** The consumer named when this was
first written down was a browser extension, which is a second product with its
own store review and its own relationship to Twitch's markup — an awkward one
next to the README's "not affiliated" paragraph.

For every consumer that *does* exist, App Intents is the better transport. A
Shortcut that opens a URL has no typed parameters, no return value and no way
to report failure; the same Shortcut calling an intent has all three.

The residual argument is third-party tooling — Raycast, Alfred, Keyboard
Maestro, Stream Deck — which all open URLs trivially and none of which speak
App Intents. That is real, and it is an integration hook for power users, not
the browser hand-off it was originally proposed as. Revisit it if those users
ask; do not build it in advance of them.

There is also a build cost the intent does not have. The project sets
`GENERATE_INFOPLIST_FILE` with no `Info.plist` of its own, and `CFBundleURLTypes`
is an array of dictionaries with no `INFOPLIST_KEY_` equivalent — so a scheme
means introducing a plist, or an `INFOPLIST_FILE` partial that merges. App
Intents is discovered from the binary and touches none of it. **Unverified**:
the exact merge behaviour was reasoned about, not tried.

### 10.3 Extracting a `JobComposer` into `OxbowKit`

See §4. Right for a codebase where the composition is tangled in a view; this
one's is not.

### 10.4 Solving VOD expiry here

The strongest version of "make Oxbow feel magical" is not a faster way in — it
is not needing to remember. VODs expire; a missed one is unrecoverable; a
watcher that queues new VODs from a channel is the only feature discussed that
changes what the app *is* rather than how fast you reach it.

It is not in this document because it is genuinely large and genuinely
different: polling Twitch's undocumented GraphQL on a schedule, an app that
wants to run rather than be opened, and a posture question — "save this VOD for
the flight" and "continuously archive a channel" read very differently beside
the copyright paragraph in the README. It gets its own design doc and its own
session.

The one thing this document owes it: **§5's `QueueHost` is the piece a watcher
needs too.** Anything that enqueues without a window has the same problem, and
solving it once here is most of why the intent is worth building first.
