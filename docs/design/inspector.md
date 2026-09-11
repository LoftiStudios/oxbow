# The inspector, and why Get Info stays a window

**Status:** written 2026-09-10. Not implemented.

`docs/design/video-record.md` §4 made Get Info a window keyed by a video
rather than a job. `docs/design/watching-navigation.md` §9.2 deferred the
question this document answers, and should now point here rather than carry
it.

This adds a trailing inspector to the main window — the pane that follows the
selection and says what you are looking at — **beside** the Get Info window,
not instead of it.

---

## 1. What is missing, stated as a person meets it

Everything Oxbow knows about a video is behind a deliberate gesture. ⌘I or a
context menu opens a window, and the window has to be closed again.

That is the right cost for "keep this in front of me". It is the wrong cost
for the job the Watching side actually has: arrowing down a hundred archives
deciding which ones to grab. Paying a window per row makes the question not
worth asking, so it does not get asked — and the record now holds category,
qualities, four sampled frames and a raw payload that nothing ambient ever
shows.

The queue has the same gap in a quieter form. A row says a title and a
progress phase. What it is, where it will land, and how big it will be are all
one window away.

---

## 2. The apparent conflict, and why there is none

`OxbowApp.swift:333` argues specifically for the window, in two clauses:

> asking for info on the same job twice focuses the window that is already
> open instead of stacking duplicates, and two downloads can be compared side
> by side — which is what Finder's ⌘I does and what a single
> follows-the-selection panel cannot.

Both true. Neither is an argument against this, **because Finder has both.**
⌘I opens a Get Info window, one per item, as many as you like, persisting
until closed. ⇧⌘P shows the Preview pane, which follows the selection and
shows exactly one thing. Nobody experiences those as competing, because they
answer different questions:

| | answers | cost | count |
|---|---|---|---|
| **Pane** | what am I looking at *now* | none | exactly one |
| **Window** | I want to keep this in front of me | a gesture | as many as you open |

Oxbow has the second and has never had the first. So the window is not
replaced, not demoted, and not reduced in scope — **§9.2's framing of this as
a trade was wrong**, and this document supersedes it.

---

## 3. Where it attaches, and how it learns what is selected

### 3.1 On the split view, under the banners

`.inspector` attaches to the `NavigationSplitView`, not to the `VStack` that
wraps it. `QueueView`'s banners span the whole window on purpose — "Downloads
unavailable" is a fact about the app, not about the visible pane — so they
stay above the inspector as they stay above everything else.

### 3.2 The selection has to be hoisted, and `focusedSceneValue` is not the way

Three destinations, three selections, and two of them are private:

| Destination | Selection | Owner |
|---|---|---|
| Queue | `Set<JobID>` | `QueueView` (`:63`) |
| Watching inbox | `Row.ID?` | `WatchingView`, private `@State` |
| One channel | `Row.ID?` | `ChannelView`, private `@State` |

`focusedSceneValue` is this codebase's existing idiom for lifting
selection-derived values — `queueActions` and `watchingActions` both do it —
and it is the obvious thing to reach for. **It is rejected here.** Every
current use is a descendant publishing *to the menu bar*, a scene-level
consumer outside the view tree. Having `QueueView` read a value its own
subtree published is a different data flow, and whether it settles reliably on
every rebuild is not something to discover through a pane that intermittently
blanks.

So: `QueueView` gains **one** `@State var watchingSelection: WatchingModel
.Row.ID?`, handed to `WatchingView` and `ChannelView` as a `@Binding`. The
queue's own selection already works exactly this way.

**One piece of state, not one per destination.** An archive id is resolved
against whatever is showing; select a row in LeighXP, switch to AvaBamby, and
it resolves to nothing. That is the correct behaviour and it costs no reset
step — a stale id simply matches nothing. Archive ids are unique across all of
Twitch (`WatchingView` already relies on this), so an id cannot accidentally
match a row in the wrong channel.

### 3.3 The subject is a pure function

```swift
enum InspectorSubject: Equatable {
  case nothing
  case one(InfoTarget)
  case many(MultiSelection)
}

/// Everything §5 renders, resolved before the view is built.
struct MultiSelection: Equatable {
  /// The true count, which is not `thumbnails.count` — that one is capped.
  var count: Int
  /// Rendered as "2 queued · 1 failed"; only non-zero entries appear.
  var queued: Int
  var running: Int
  var done: Int
  var failed: Int
  var cancelled: Int
  /// **Nil when any selected job could not be priced** — §5.3. Not zero,
  /// and not a partial sum.
  var estimatedBytes: Int64?
  /// Queue order, capped at four. A `nil` entry is a job whose video has no
  /// thumbnail and draws a placeholder tile, keeping the stack's shape.
  var thumbnails: [URL?]
}
```

derived from the sidebar destination, the two selections, the sections and the
jobs. **This is the whole behavioural surface of the feature**, it takes no
view to exercise, and it goes in `OxbowTests` — the same move
`ChannelCard.disconnectedVolume(in:)` and `WatchingModel.listings(from:)`
already make for the same reason.

`.many` can arise only from the queue, because both Watching destinations are
single-select. Encoded rather than left implicit: a future multi-select in
Watching should have to come here and say so.

`InfoTarget` already exists and is already the right shape — a two-case value
naming either a video id or a `JobID` (`video-record.md` §4.2), built so queue
rows and archive rows could address one window. The inspector reuses it whole.

---

## 4. One thing selected

**The card is shared with the window and identical.** `VideoCard`, with its
three existing states — `loading`, `loaded`, `unavailable`. This is the one
element that must not fork, and it is the element `video-record.md` §4.1
already nominated: intake and Get Info "stay two windows sharing one
component."

**The sections beneath it are each pane's own business.** That is the same
§4.1 principle, not a departure from it — that section's whole point is that
two surfaces share a component while answering opposite questions underneath.
So the rule for the 300pt problem is simple and it is not a compromise:

| | Card | Download facts | Steps | Delivered files |
|---|---|---|---|---|
| **Inspector** | ✓ identical | Status · Outputs · Quality · Trim · Filesize | — | Show in Finder |
| **Window** | ✓ identical | Status · Outputs · Quality · Trim | ✓ full | ✓ full list |

**Every value in that column is `JobInfo`'s**, the same property the window's
own Download section reads — `outputs`, `quality`, `trim` — rendered by the
same `JobStatusValue` and closed by the same `SavedToFooter`. The two surfaces
show a different *amount* and never a different *answer*.

**Filesize is the inspector's alone, and it is the one thing here the window
does not show.** It is the delivered files' actual size on disk rather than an
estimate, and it follows §5.3's rule rather than the estimate's: shown only
when every delivered file could be measured, absent when one could not. A file
on an unmounted volume has no size to report, and a total quietly omitting it
would read as a smaller download rather than an unmeasured one.

Show in Finder is the one ambient *action* worth carrying, because "where did
that go" is asked far more often than "which of the four steps failed".

Keeping the full step breakdown in the window is also what stops the two
drifting into "why do both exist". The window is not a wider inspector; it is
the one that shows the work.

---

## 5. Several selected

Queue only. Counts always, bytes only when honest, and a visible stack above
both.

### 5.1 The stack

Apple Mail's shape: the selected items' thumbnails, overlapping, above the
summary text. It does the work a count alone cannot — it says *these* three,
with their artwork, so a mis-selection is visible before you act on it.

- **Capped at four**, with the count beneath carrying the true number. A fan
  of forty is a smear.
- **Ordered by queue position, never by the selection itself.** `selection` is
  a `Set<JobID>` and a `Set` has no order — a stack rendered straight from it
  would reshuffle on every rebuild, which reads as a glitch and is the kind of
  thing that survives review because nobody scrolls twice. Queue order is
  stable and matches what is on screen.
- **A missing thumbnail is a placeholder tile, not a gap.** A job whose video
  has no record has no artwork; the stack keeps its shape rather than
  collapsing, the same way `FilmstripThumbnail` plays a single frame straight
  rather than breaking on a count of one.
- Images come from `ImageStore` — already keyed by SHA-256 of the URL, already
  the store the card reads — so this adds no fetching.

### 5.2 What the text says

```
3 downloads selected
2 queued · 1 failed
~12.4 GB estimated
```

**The status counts are free** and always shown: they are on the jobs.

**The failure count is the line that earns this feature.** Selecting a run of
rows and reading "4 failed" is how a person notices a systematic problem —
a destination gone, a channel that is subscriber-only — without scrolling
through them one at a time. It is always computable and it is never omitted.

### 5.3 The byte line is conditional, and this is the important rule

`BackfillEstimate(archives:cap:output:)` prices `ChannelArchive`s off their
`duration`. **A `Job` does not carry one** — its download step holds a
destination, a quality and a video id. So pricing a selection of jobs means
resolving each `mediaIdentifier` through `VideoRecordStore` to a
`VideoRecord`, whose `durationSeconds` is `Int?` and can be absent.

**So the byte line appears only when every selected job could be priced.**
When some could not, it is omitted entirely rather than quoting a total that
silently drops two of five.

This is the same rule this repository already applies three times, and it is
worth stating as a rule rather than as a special case:

- `totalCount` overcounts, so a backfill is sized from the edges actually
  received (`twitch-channel-api.md` §5.1);
- `nearestExisting` refuses to collapse "could not ask" into "the answer is
  no", because doing so read a NAS with 8 TB free as a full disk;
- `ChannelCard` names one disconnected volume rather than inventing a summary
  across several, because that "would be a claim nothing here actually
  computed".

A number that looks complete and is not is worse than an absent number, and a
disk figure is precisely the kind people act on.

---

## 6. Nothing selected

A placeholder. Deliberately **not** the channel card, and **not** queue
totals.

Both are tempting and both are wrong for one reason: they would make the
inspector show a different *kind* of thing depending on state. A pane whose
subject changes category when you deselect is one you cannot predict, and
predictability is the entire value of an ambient pane — you stop looking at it
on purpose and start absorbing it.

---

## 7. Shortcuts and persistence

**⌘I is untouched.** It opens the window, exactly as it does now.

**⌥⌘I toggles the inspector**, plus a toolbar button, which is where every
Mac inspector lives.

**One open/closed state, shared across destinations.** Not per-pane: a control
that remembers a different answer depending on where you are standing is one
you cannot predict, which is §6's argument applied to the chrome instead of
the content.

**A shortcut this may unblock, noted rather than promised.**
`video-record.md`'s status records that ⌘I was never bound in the Watching
pane "because Get Info's shortcut would have to coexist with the queue's."
With `isShowingWatchingSide` now existing and the destinations distinct, a
single command resolving "the visible pane's selection" is available — and if
the inspector is carrying the ambient question, the pressure on ⌘I is mostly
gone anyway. Not in scope here; recorded so the next person does not
rediscover the constraint and assume it still binds.

---

## 8. What this costs

**Width.** The window's floor is 660pt (480 + 180, set in `QueueView`'s
`.frame`). An inspector wants 280–320, so comfortable use lands near 1000.
It is collapsible and its state is remembered, but on a laptop this is a real
ask and it is the single most likely reason to dislike the feature.

**A second place a video is drawn.** Mitigated by §4's shared card rather than
eliminated. The failure mode to watch for is not the card diverging — it is
someone adding a fact to the window's sections and not the inspector's, so the
two answer the same question differently. The table in §4 is the contract.

---

## 9. Testing

The pure part carries it, as everywhere else here:

- **`InspectorSubject` derivation** — every combination of destination and
  selection, including a stale `watchingSelection` that matches no row in the
  visible channel, which must be `.nothing` rather than a wrong row.
- **`.many` never arises outside the queue**, asserted directly, since both
  Watching destinations are single-select and a future change there should
  have to come back to this document.
- **The byte line is omitted when any selected job cannot be priced**, and
  present when all of them can. Mutation-check this one: it encodes a
  distinction ("incomplete" ≠ "smaller") that a test can appear to cover while
  passing against the wrong behaviour, exactly as `video-record.md` §9 says of
  its own two.
- **Stack order is queue order**, asserted against a selection built in a
  different order from the queue — a `Set` will often *happen* to iterate in a
  plausible order, so a test that builds the selection in queue order proves
  nothing.
- **A job with no thumbnail yields a placeholder tile**, keeping the stack's
  count, rather than a shorter stack.

The views themselves stay hand-verified, per `docs/development.md`.

---

## 10. Staging

Each stage changes something visible.

**Stage 1 — the pane exists and follows a single selection.** Hoist
`watchingSelection`, add `InspectorSubject` and its tests, attach `.inspector`,
render the `.one` and `.nothing` cases with the shared card. Visible
immediately: select anything anywhere, see it.

**Stage 2 — the multi-selection summary.** Counts and the conditional byte
line, text only.

**Stage 3 — the stack.** Mail's overlapping thumbnails above that text.
Deliberately last: it is the part with no behaviour, so it is the part most
safely cut if stage 2 turns out to read fine without it.

**Stage 4 — ⌥⌘I and the toolbar toggle**, if they have not landed with
stage 1.

---

## 11. Rejected

**Replacing the Get Info window.** §2. The two answer different questions and
Finder ships both.

**`focusedSceneValue` for the selection.** §3.2 — the existing uses are a
descendant publishing to the menu bar, which is not this.

**A per-destination inspector toggle.** §7.

**Showing the channel or the queue when nothing is selected.** §6.

**Quoting a partial byte total.** §5.3.

**A second, compact card for narrow widths.** The card is the one thing that
must not fork (§4). If it does not work at 300pt the answer is to make it
work, not to grow a variant that will drift.

---

## 12. Open question

**Does the inspector make the window's per-item duplication rule feel wrong?**
Today asking twice about one video focuses the open window. With an inspector
carrying the ambient case, the window's remaining job is comparison — and
comparison is the case where you might *want* two windows on the same video at
different scroll positions. Not changed here, and probably never worth
changing; recorded because the reasoning behind that rule shifts once this
ships, even though the rule itself still holds.
