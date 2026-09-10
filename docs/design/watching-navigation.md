# Channels as destinations

**Status:** written 2026-09-10. Not implemented.

`docs/design/channel-watching.md` built the watcher and put it behind a
sidebar row. `docs/design/channel-history.md` gave a watched channel contents.
`docs/design/video-record.md` made those contents durable, and in doing so
turned downloads into rows. This document is about where all of that now
*lives*: the sidebar grows a row per watched channel, and each one is a
destination showing everything Oxbow knows about that channel.

Where §8 of `channel-watching.md` describes the sidebar as two rows, this is
later and wins. Nothing else in that document changes — §2.2's inbox is
preserved deliberately and at some cost, and §3 of this document is mostly an
argument for why.

---

## 1. The problem, stated as a person meets it

**The first column holds two rows and the second column holds everything.**
`QueueView.swift:172` builds a `NavigationSplitView` whose sidebar is `Queue`
and `Watching`, and whose detail pane, on the Watching side, carries every
watched channel, every channel's settings, every channel's findings, every
channel's downloads, and a fold per channel hiding everything else. One column
is nearly empty and the other is doing all the structural work.

**And the pane is two features stacked in one scroll.** It is an *inbox* —
what is new, act on it, `Add` or `Ignore` — and, since the video record made a
download into a row, it is also a *library*: what you have, what you skipped,
what Twitch has since dropped. Those want different layouts, different orders
and different empty states, and today they are compromising with each other
inside a single `List`.

Three symptoms, all of them consequences of that compromise rather than
independent bugs:

- **`ChannelCard` is an 88pt card used as a repeating section header.** It is
  the right size for the thing it describes and the wrong size to appear four
  times down one scroll. Worse, as a pinned header it has no opaque
  background, so the next channel's card scrolls visibly through it. Measured
  2026-09-10 on the running app: two captures seconds apart, byte-identical,
  showing two avatars and two settings lines overlapping at the top of the
  pane. This is a resting state, not a frame mid-scroll.
- **`Show 100 skipped or missed` is a disclosure fold**, and pressing it
  expands a hundred rows *underneath the row you were reading*, pushing
  everything else off screen. It is the only way to reach a channel's history
  and it is a bad one.
- **The stand-in rows are row-shaped because they have to be.** `FailureRow`
  and `EmptyChannelRow` are one-line labels rather than real empty states
  precisely because they sit among other channels' sections and must not
  shout over the quiet ones next to them. That constraint is real, and it is
  imposed by the layout rather than by the content.

---

## 2. What this delivers

**A row per watched channel in the sidebar, under `Watching`.** Mail's
`All Inboxes` shape: a selectable parent that keeps its own meaning, with the
individual sources beneath it, each carrying its own count.

**A destination per channel**, showing that channel's complete record — what
you have, what is queued, what you skipped, what expired — with `ChannelCard`
as the pane's header rather than as a header pinned over rows.

**`Watching` unchanged.** It is still the inbox §2.2 of `channel-watching.md`
argues for, still cross-channel, still badged. This work adds destinations
beside it; it does not redistribute it.

**A control deleted rather than restyled.** Once a channel has a destination,
`Show N skipped or missed` is a worse way to reach the same rows, and it goes.

**Two stand-in rows promoted to real empty states**, because alone in a pane
they are no longer at risk of shouting over anybody.

---

## 3. `Watching` survives, and why that is not just conservatism

§2.2 of `channel-watching.md` is explicit that a notification is a pointer and
the durable list is the product: "It appears while you are in a meeting, gets
swiped away with forty others, and the archive expires anyway." The durable
list is the feature.

**An inbox's defining property is that it is one place.** Break the channels
out and hand each one its own count, and "what is waiting for me" becomes four
places to look and four numbers to add up — which is a notification's failure
mode reintroduced as a layout. The reason to break channels out is that the
*library* deserves a home, not that the inbox needed dividing.

So both exist, and the boundary between them is not a new idea:

### 3.1 The boundary already exists as a function

`WatchingModel.belongsInTheDefaultView` (`WatchingModel.swift:888`) already
decides, per row, whether something is inbox material:

```swift
if row.state.holdsAFile { return true }
if row.state == .queued || row.state == .running { return true }
if dismissed.contains(row.archive.id) { return false }
if let state = library.watchStates[row.archive.id] { return state.isVisibleByDefault }
if watch.seen.contains(row.archive.id) { return false }
return live[row.archive.id] != nil
```

That predicate is the inbox/library split, written down, shipped, and
currently expressing itself as a disclosure fold. This document does not
invent a boundary; it gives the far side of an existing one a destination.

`Watching` shows rows where it is true. A channel shows `resolved` — the list
that predicate filters — unfiltered.

### 3.2 The count is the existing count, un-summed

`WatchingModel.unreadCount` (`WatchingModel.swift:117`) is already:

```swift
sections.reduce(0) { $0 + $1.rows.filter { $0.state == .available }.count }
```

The per-channel badge is that expression without the `reduce`. No second
counting rule, no new state, and no way for the parent and the children to
disagree about what a waiting item is — the parent is by construction the sum
of the children.

Its doc comment already carries the reasoning that matters: it "counts only
rows a person still has to act on," because a badge that counted queued and
downloaded rows "would never reach zero."

**A channel with nothing waiting shows no number.** Not a zero. This is Mail's
rule — measured on the reference screenshot, two of four accounts carry no
badge at all — and it is already this codebase's rule: `WatchingView`'s own
doc comment argues against a "no new videos" row under every quiet channel on
the grounds that it would be "the loud thing on a screen that is trying to be
quiet." A column of zeroes is the same mistake in a smaller font.

### 3.3 Only a decision clears it. Visiting does not

**This is the one place Mail's analogy would mislead if imported whole.** Mail
marks a message read when you look at it. Doing that here would let a channel
go quiet because you glanced at it, which is precisely the miss the entire
feature exists to prevent — and it would do so silently, since the evidence
that you had missed something is the number that just disappeared.

A row leaves the count when it stops being `.available`: `Add` queues it,
`Ignore` dismisses it. Both are decisions. Selecting the channel in the
sidebar is not one, and changes nothing.

The asymmetry is the same one `channel-watching.md` §4 draws about the
seen-set, and the same one §3.5 of `video-record.md` draws about what earns a
row: watching a channel is a standing instruction to keep track, and looking
at a list is not an instruction at all.

---

## 4. The sidebar

```
Queue
Watching             3     ← the inbox; badge is the sum of the four below
  AvaBamby                 ← nothing waiting, so no number at all
  LeighXP            3
  Middleditch
  WheelyF        ⚡        ← downloads automatically, nothing waiting
```

### 4.1 Alphabetical by display name

Predictable, and stable across sweeps. Ordering by most recent activity would
be more useful for about a day and would also mean the sidebar reshuffles
under the pointer every time a sweep lands — which is how a person clicks the
wrong channel. Mail orders accounts by a rule the user set and never moves
them on its own; this is the cheap version of the same promise.

Display name rather than login, matching what `ChannelCard` shows and what a
person recognises. `video-record.md` §3.4 is the reminder that these are two
different strings and that neither derives from the other.

### 4.2 `.badge()` before `.tag()`, on every one of them

`channel-watching.md` §8.1 bisected a macOS 26 SwiftUI regression by hand:
applying `.badge()` to a row's label *after* `.tag()` stops that row's clicks
from ever reaching the selection binding. The row highlights, AppKit fires,
and `selection` never updates.

Today there is exactly one badged row in this sidebar and one inline comment
guarding it. This adds one per watched channel, each of them a fresh
opportunity to reintroduce a bug whose symptom is "clicking does nothing" and
whose cause is modifier order. The order is load-bearing; it is not a style
preference and it is not optional.

### 4.3 The channel case has to be handled everywhere `SidebarItem` is

`SidebarItem` (`QueueView.swift:72`) is a two-case enum, and both of its
consumers are written as switches with a `case .queue, .none:` catch-all:

- **The detail builder.** A new case that falls through lands you on the queue
  when you clicked a channel.
- **The toolbar.** The condition is `sidebarSelection == .watching`, so a
  channel destination would silently lose `Refresh` and `Add Channel` and gain
  the Queue's `Add Download` — a button that opens intake for a brand-new job
  sitting in a pane full of a specific channel's videos, which is exactly the
  misreading the existing comment there says it was placed to avoid.

Adding `case channel(String)` and letting the compiler find the switches is
the whole technique. It works only if neither switch keeps a default that
absorbs it, so both catch-alls become explicit.

### 4.4 Stopping a watch falls the selection back to `Watching`

A destination pointed at a watch that no longer exists renders nothing and
offers nothing, and `Stop Watching` is reachable from the sidebar row itself,
so it is not a rare path. The selection moves to the parent, which is always
there.

### 4.5 Edit and Stop Watching are added to the sidebar row, not moved to it

Both live on `ChannelCard` today — in its `‹…›` menu and its context menu,
defined once in `ChannelCard.actions` and rendered by both. With a channel now
addressable in the sidebar, its row gets the same pair on right-click, which
is where Mail puts the equivalents for an account.

**The card keeps them.** It is still the header of the channel's own
destination, and the `‹…›` button is the visible route — added specifically
because, in that comment's words, both actions "lived only in the right-click
until now, which the app's own author could not find." Taking it away again to
put the same pair behind a different right-click would repeat exactly that.

**Defined once, still.** The reason `ChannelCard` renders one `actions`
builder in two places is that two copies drift, and the first divergence is a
menu offering something the other does not. A third rendering site does not
change that argument, it strengthens it — the builder moves somewhere both the
card and the sidebar row can reach.

---

## 5. The channel destination

**`resolved`, unfiltered, newest first.** Every state `ArchiveRowState` can
produce, including the ones the inbox holds back — `downloaded`, `missing`,
`expired`, `unverifiable` — plus the rows it hides for reasons that are not
states at all: ones already in the seen-set, and ones you ignored. Same
`ArchiveRow`, same badges, same context menus, same row selection and Return
that stage 3c of `video-record.md` shipped. This is a new destination for rows
that already render — not a new row.

(⌘I is deliberately *not* claimed here. That stage's own status note records
that the key equivalent was not built, because Get Info's shortcut would have
to coexist with the queue's — an unresolved question this document does not
reopen.)

Newest first, matching the order the sweep returns and the order a channel
page reads in.

### 5.1 The card heads the pane and scrolls with it

Not a pinned header. Nothing is above it to collide with and nothing scrolls
through it, so §1's transparency symptom is answered by relocation rather than
by a background fill — and the 88pt avatar is finally proportionate, because
it is heading a whole pane instead of repeating four times down one scroll.

The disconnected-volume notice rides along on the card, where it already
lives and where `ChannelCard`'s own doc comment argues it belongs: one plain
statement at the level a whole channel's rows share it.

### 5.2 Failure and emptiness become pane-level

`FailureRow` and `EmptyChannelRow` are one-line labels because of a constraint
that a destination removes. Alone in a pane they become
`ContentUnavailableView`s: a failed sweep gets a real "Couldn't check LeighXP"
carrying the message, rather than a label impersonating an archive.

**The distinction those two rows exist to protect is unchanged.** A failed
channel must never look like a quiet one — `WatchingModel.Section.failure`
exists precisely so those two states cannot be confused, and promoting the
presentation must not blur what is being presented.

### 5.3 `Refresh` stays global, and stays honest

`WatchPoller.sweep` checks every watched channel; there is no per-channel
fetch to bind a per-channel button to. The existing tooltip already says
"Check the watched channels for new archives now" — plural — so the button
reads correctly sitting in a single channel's pane without any change.

A per-channel `Refresh` is rejected in §9.

### 5.4 Not in this pane

No per-month grouping, no sort control, no filter. A library that wants them
will say so once it exists, and inventing them now would be three controls
designed against a guess.

---

## 6. What is deleted

**`Show N skipped or missed`, and the state behind it.** `revealed`,
`revealedLogins`, `toggleHidden(for:)`, `Section.hiddenCount`, and the
`belongsInTheDefaultView` branch that consults `revealed` — the fold's far
side now has a destination, and the destination is better in every way that
matters: it has a title, it does not displace what you were reading, and it
can be reached without first scrolling to the bottom of a channel.

**Deliberately not in the first stage.** Removing it is a change to the inbox,
and §8 keeps the inbox untouched until its own question is answered. It is
staged separately for that reason, not because it is difficult.

---

## 7. Testing

The pure parts carry the weight, as everywhere else here. `WatchingModel` is
testable; the views are not, and §"The SwiftUI layer is verified by hand" in
`docs/development.md` is why the list below stops where it does.

- **The per-channel count equals the parent's, decomposed.** Given several
  sections, the sum of the per-channel counts is `unreadCount`. This is the
  property that makes the parent honest, and it is one line to assert and easy
  to lose to a well-meaning refactor of either expression.
- **A channel with no `.available` rows produces no badge**, distinctly from
  producing a zero — the two are different values and only one of them is
  allowed to reach the row.
- **Visiting does not clear.** Selecting a channel leaves every count where it
  was. Mutation-check this one: it encodes a distinction ("looked at" ≠
  "decided") that a test can appear to cover while passing against the wrong
  behaviour, exactly as `video-record.md` §9 says of its own two.
- **The unfiltered list is a superset of the filtered one.** For every
  channel, the inbox's rows are a subset of the destination's, with the
  difference being precisely the rows `belongsInTheDefaultView` rejects.
- **Stopping the selected watch leaves the selection resolvable** — falls to
  `Watching` rather than to a channel case naming a login no longer in
  `watches.json`.

The two switches in §4.3 are checked by the compiler once their catch-alls are
made explicit, which is better than a test and is the reason to make them
explicit.

---

## 8. Staging

Each stage changes something visible. This is `docs/development.md`'s
"Planning work" rule applied deliberately, against a feature whose predecessor
(`video-record.md` stage 3a) shipped twenty-three commits whose entire output
was a JSON file.

**Stage 1 — the channels appear, and clicking one works.** Sidebar rows with
badges, `SidebarItem.channel`, both switches, the destination showing the full
list with `ChannelCard` as its header. The inbox is untouched — byte for byte
what it is today. Visible the moment it builds: four new rows, and a place to
go.

**Stage 2 — the destination's own manners.** Pane-level empty and failure
states, Edit and Stop Watching on the sidebar row's context menu, selection
falling back when a watch is stopped.

**Stage 3 — the fold is retired.** `Show N skipped or missed` and its state
come out of the inbox, now that its far side has a home. Visible as a control
disappearing, which is the point.

**Independent of all three: the pinned header's background.** §1's
transparency symptom is a one-line fix that stands on its own and can land at
any point, including before stage 1. It is listed here so it does not get
absorbed into a stage that would obscure whether it worked.

**Stage 4 is the open question in §9.1**, and stage 5 is §9.2. Neither is
scoped here.

---

## 9. Open questions

### 9.1 Does the inbox stay grouped by channel?

With channel identity now living in the sidebar, the inbox could go flat and
reverse-chronological across every channel — Mail's `All Inboxes` — with each
row carrying a small avatar to say whose it is. "What did I miss" is arguably
a question about *time*, and yesterday's four VODs from three people belong
next to each other.

Against: it is the larger change to what is on screen, and grouping is what
the pane does today.

**Deliberately deferred rather than decided.** Stage 1 does not touch the
inbox, so this can be answered after the channel destination has been used for
a while — which is a better position to answer it from than a guess made
before either half exists. Carried the way `channel-history.md` §5.3 carries
the `4/20` counter: at roughly even odds, and built to be deleted if the
answer is no.

Note that the answer changes what §6 leaves behind. A flat inbox has no
per-channel section to hang a fold on at all, so `revealed` dies either way;
a grouped one keeps the option of a lighter header.

### 9.1a A hundred Add buttons that cannot work

Observed 2026-09-10, once the destination existed: a channel watched for six
months shows its whole back catalogue, and every row of it offers `Add` —
because those archives are `.available`. They are still on Twitch and merely
`seen`, so the state is literally correct.

For a subscriber-only channel it is correct and useless. Every one of those
buttons starts a download that fails at the manifest.

**Two things were wrong with the first version of this section**, both found
on 2026-09-10 by looking at what the app had actually done rather than at what
it was designed to do.

**First: the detection never fired at all.**
`AutoDownloadPolicy.isContentRestricted(jobs:)` counts failures carrying
`FailureInterpreter.subscriberOnlySummary`, which was produced only for stderr
containing `vod_manifest_restricted` or `unauthorized_entitlements`. Those are
what `usher` answers a **direct manifest request** — the probe
`twitch-channel-api.md` §9.3 ran by hand. Oxbow never makes one. The CLI
swallows the 403 inside `VideoDownloader.GetQualityPlaylist()` and rethrows
`System.NullReferenceException: Insufficient access to VOD, OAuth may be
required.`, which fell through to the unknown-error fallback and produced a
perfectly readable sentence that was not the constant anything matched on.

Measured across **84 real failures on `middleditch`** — the same channel §9.3
was measured against — with automatic downloading on. The demotion that should
have stopped the sweep at three never fired, so it attempted the whole channel
until a person cancelled it by hand at around eighty. **Fixed**: `summarise`
now matches the CLI's own wording, and `FailureInterpreterTests
.recognisesTheCLIsOwnSubscriberOnlyWording` pins it to captured stderr rather
than to an invented string.

The lesson generalises past this bug: the test that covered this case used a
synthetic fixture nobody had observed the CLI emit, so it stayed green for
months while the behaviour it described never happened. `twitch-metadata.md`
§7 already says an exit code is not evidence; a hand-written fixture is not
either.

**Second: for a manual channel the knowledge is computed and discarded.**
`WatchPoller` calls `isContentRestricted(jobs:)` for every watch, but
`AutoDownloadPolicy.decide` returns `.notAutomatic` at its first guard — seven
lines above the `contentRestricted` one — so a channel with
`downloadsAutomatically: false` can fail every archive it has and nothing is
ever concluded. The manual `Add` on each row consults none of it and keeps
offering.

**Deliberately punted, 2026-09-10.** With the matcher fixed, an *automatic*
channel now stops at three and its card says why, which is the case that was
actively harmful. A *manual* channel still offers a hundred Adds that cannot
work, and there is no good fix available: the only up-front probe is a manifest
request per archive (§9.3), and a channel-level inference drawn from three
failures would lock out ninety-six rows nobody has evidence about. Both
alternatives are worse than the status quo. **The real answer is
authentication, which this project has deliberately chosen never to do**
(§2 of `twitch-channel-api.md`), so this stays open rather than being solved
badly.

Note what that policy's own doc comment establishes, because it constrains
every fix: Twitch's metadata **cannot** be asked. §9.3 of
`docs/twitch-channel-api.md` measured a members-only channel reporting 908
archives with `resourceRestriction` null and `self.isRestricted` false, the
refusal arriving only at the manifest. So the signal is retrospective by
nature — there is no per-archive fact to render, only a channel-level
inference drawn from what already failed.

Which makes this a question about what a demoted channel's *rows* should
offer, not about adding a new row state. Deliberately not answered here: it
wants the library pane to exist first, and it is entangled with §9.1 —
a flat inbox and a per-channel library have different answers, because the
inbox has few rows per channel and the library has hundreds.

### 9.2 Does Get Info become an inspector?

The original shape this document came from was three columns: sidebar, list,
and a trailing pane showing the selected row's info — Agenda's layout, and the
one Notes, Freeform and Xcode use.

It is a real improvement to argue for and it is not free. `OxbowApp.swift:333`
records why Get Info is a `WindowGroup(for:)` today, and the reasons are
specific: asking twice about the same video focuses the open window instead of
stacking duplicates, and two videos can be compared side by side — "which is
what Finder's ⌘I does and what a single follows-the-selection panel cannot."
`video-record.md` §4.1 says the same. An inspector genuinely cannot compare
two things.

The other cost is width: the window's floor is 660pt (480 + 180) and an
inspector wants 280–320, putting comfortable use near 1000.

Worth doing, worth doing after this, and worth its own document — including
whether ⌘I still tears off a window for the comparison case, or whether that
case is conceded.

---

## 10. Rejected

**Channels replacing the `Watching` row.** The reason the sidebar has room is
that the pane is overloaded, not that the inbox was redundant. §3.

**Marking a channel read on visit.** Mail's rule, and wrong here for the
reason §3.3 gives: it turns "I glanced at this" into "I dealt with this,"
silently, in the one feature whose entire purpose is not missing things.

**Ordering the sidebar by most recent activity.** §4.1 — it reshuffles under
the pointer.

**A per-channel `Refresh`.** There is no per-channel fetch. `WatchPoller
.sweep` is all-channels and sequential — one request per channel with a
15-second timeout, which is why `WatchingView.isSweeping` exists to cover a
gap that "can run to minutes" — so a per-channel button would either sweep
everything under a label that says otherwise, or need a second fetch path
built to serve a button.

**A three-column `NavigationSplitView`.** What Agenda actually does — and what
§9.2 would do — is sidebar, content, and a trailing `.inspector`. An inspector
is collapsible, remembers its width, and gets a toolbar toggle for free; a
third `NavigationSplitView` column is a navigation destination, which the info
pane is not.

**Restyling the fold instead of deleting it.** §6. The problem with
`Show 100 skipped or missed` is not that it looks like a row; it is that
expanding a hundred rows under the row you were reading is the wrong gesture
no matter how it is drawn.
