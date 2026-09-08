# A watched channel with contents

**Status:** design, written 2026-09-07. **Stages 1 (§7.1) and 2 (§7.2) implemented**; stage 3 not started.

`docs/design/channel-watching.md` built the watcher. This describes what a
watched channel should *look* like once it has been watching for a while, and
the record that has to exist behind it. Where that document and this one
disagree, this one is later and wins; §3.1 and §4 of it are the parts most
directly amended.

Every claim about Twitch's API is measured in `docs/twitch-channel-api.md`
rather than argued here.

---

## 1. The problem, stated as a person meets it

You paste a channel, press Add, and get **one row that does nothing**. If you
do not think to click over to Queue, nothing in the app ever tells you a
download happened. The channel is a line item in a list, not a thing with
contents — and the contents are the entire reason you added it.

Underneath that, the record is nearly empty. A watch stores its login, its
frozen settings, and a set of bare archive ids:

```json
"seen": ["2816117318", "2849239087", "2851023468", "2817008237"]
```

No title, no date, no path, no thumbnail. `ChannelArchive` is deliberately not
`Codable` (§4 of the watching design), so every sweep fetches metadata,
renders it, and throws it away. The moment an archive is queued, the only
trace it leaves is an opaque number. Once it expires off Twitch and its job is
removed from the queue, **nothing anywhere records that it existed**.

So "what have I got from this channel" is not a question the app can answer,
and that is the question a person actually has.

---

## 2. What this delivers

**A channel is a card with contents.** Avatar, name, the settings it is frozen
to, a coverage counter, and beneath it one list.

**One list, not two.** Findings and history are the same rows in different
states. An archive you could get, one being fetched, and one you already have
are three states of one thing, and splitting them into an "inbox" and a
"library" would make you learn which pane a video is in before you can act on
it.

**The filesystem decides what you have.** A row claiming you have a file is
shown only when the file backs the claim. Delete the download and the row
stops claiming it.

---

## 3. The record

A store of its own, keyed by channel login, separate from `watches.json`.

**Separate because `watches.json` is small, hot and contended.** Three writers
rewrite it wholesale — the sweep, the Watching pane, the Add Channel window —
and the ordering discipline between them has already produced eight bugs of
one shape. Growing it into an append-mostly log of every archive a channel has
ever produced, rewritten on every mark-seen, would invite the ninth.

One entry per archive:

| Field | Why |
|-------|-----|
| `id` | Twitch's archive id. The join key to everything. |
| `title`, `duration`, `publishedAt` | So an expired archive still renders. |
| `state` | §3.1. |
| `deliveredPath` | Where the download landed. §4 checks it. |
| `lastSeenOnTwitch` | The sweep stamps this. Absent from the newest sweep means expired. |
| `thumbnail` | A cache key, §6. |

### 3.1 Six states, and the end of `seen`

- **`new`** — on Twitch, not acted on. Today's finding.
- **`skipped`** — existed before you started watching. What "Only new" seeding
  produces.
- **`queued`** — submitted to the queue.
- **`downloaded`** — its job finished, and `deliveredPath` is set.
- **`ignored`** — you dismissed it.
- **`failed`** — its job failed. Actionable again, per the watching design
  §6.3.

**`seen` stops being stored and becomes derived**: *state is not `new` and not
`failed`*. That is exactly what `seen` means today.

Two parallel records of "have I acted on this archive" is the drift that
produced every ordering bug in this feature. The watching design's §4 rule —
that the seen-set must be the watcher's own state and never derived from the
queue — is untouched by this: history *is* the watcher's own state. §4's
actual target was deriving it from `Job`s, which can be removed by a person
and would silently license a re-download.

### 3.2 Migration is a one-way trip and does not have to be pretty

The feature has not shipped. There is no installed base, and the only data in
existence is the author's, which is disposable.

So: on first launch, each id in `seen` becomes a `skipped` entry with **no
metadata**, because none was ever stored and none can be recovered. Ids still
on Twitch pick up their title and date on the next sweep. Ids already expired
stay as bare numbers forever, and render as an unknown archive if the filter
ever surfaces them.

`seen` is then no longer written. Nothing migrates back, and nothing tries to.

---

## 4. The filesystem is the authority

A `downloaded` entry is a claim that a file is at `deliveredPath`. The claim is
checked, not trusted.

**The record is advisory and the disk is authoritative.** Point a channel at a
different folder and its history reads as gone, because by this rule it is
gone — those files are not where the record says they are. That is the
accepted consequence of the same "break honestly" choice made for renames: a
moved or renamed file reads as missing rather than being hunted for by name,
because a wrong guess claims you have something you do not.

### 4.1 Three answers, never two

`present`, `absent`, and **`unknown`**.

The third is not decoration. `AutoDownloadPolicy` was recently demoting every
channel pointed at a NAS forever, because
`volumeAvailableCapacityForImportantUsage` answers *zero* on a network volume
rather than nil, and every `??` fallback sailed past it. A share with 8 TB free
read as a full disk. Collapsing "could not ask" into "the answer is no" is the
same mistake, and here it would be worse: it would make your entire library
disappear from the view.

So the join asks whether the *volume* is reachable before it asks whether the
file is there.

| Volume | File | Row |
|--------|------|-----|
| reachable | present | You have it. Shown, openable. |
| reachable | absent, still on Twitch | You do not have it, and you can get it again. Returns to actionable. |
| reachable | absent, expired | Dead. Hidden by default (§5.2). |
| unreachable | — | **Never hidden.** Shown unavailable, under §4.2's banner. |

Deleting a download therefore un-does it: the row goes back to being something
you could fetch, as long as Twitch still has it.

### 4.2 A disconnected volume is one condition with two expressions

If the destination is not mounted, the channel already demotes to notify-only —
`AutoDownloadPolicy.Reason.destinationUnreachable` exists and fires today. New
archives cannot be fetched *and* old ones cannot be verified, and both follow
from the same fact.

So it reads as one condition: a banner on the channel naming the volume —
**"Helios is disconnected"** — with its rows beneath it shown unavailable
rather than absent. The volume's name, not the full path: `VolumeSpace
.volumeName` already provides it, and a path is not what a person calls a
disk.

---

## 5. What you see

### 5.1 By default: have it, getting it, could get it

Three states, which is the whole of what a person does here. Everything else
is behind the filter.

### 5.2 The filter reveals the rest

`ignored`, `skipped`, missed (expired, never downloaded), and
deleted-and-expired. These are kept forever and hidden by default: keeping
them is what lets the app answer "what did I miss", and hiding them is what
stops a channel watched for a year from becoming mostly headstones.

### 5.3 The counter, which may not survive

`4/20` is **files you have now** over **entries recorded since you started
watching**.

The numerator is a filesystem fact, so deleting a download moves it to `3/20`.

**`skipped` entries are excluded from the denominator.** They are the backlog
that already existed when the channel was added, and counting them would open
a channel added with "Only new" at `0/100` — a permanent failing grade for
work nobody asked to be done. Excluded, the fraction reads as the sentence a
person would actually say: twenty have come along since you started watching,
you have four of them.

A disconnected volume shows the disconnected state rather than `0/20`, which
would be a lie of the same kind as the NAS reading as a full disk.

**This element is provisional and should be built to be deleted.** Its value
is unproven and it is roughly as likely to be cut as kept. So it stays a pure
function over the entries plus one view element, and nothing else is allowed
to key off it — no filter, no sort, no state derived from the fraction.
Removing it should be removing one function and one label.

---

## 6. Images

Thumbnails already arrive on the sweep — `previewThumbnailURL(width: 320,
height: 180)` — and are currently used and discarded. Avatars do not; they
need `profileImageURL` added to the query.

Both are cached to disk, because an expired archive's thumbnail is gone from
the CDN and an unmounted-NAS launch should still look like the design.

**The avatar width must come from a fixed list.** `docs/twitch-channel-api.md`
§9.2 measures it: the field accepts *any* width and returns a URL built by
interpolation, but the CDN serves only 28, 50, 70, 150, 300, 600 — 100, 200,
400 and 1200 are 404s. The request must therefore never be computed from a
layout constant, or growing an avatar from 150pt to 160pt would silently start
404ing. 300 unless the view genuinely renders above 150pt at 2x.

---

## 7. Staging

Three pieces, in this order, each landing working.

### 7.1 Image store — done

Adds `profileImageURL` to the query, and a disk store keyed by a SHA-256 of
the image URL.

**Three departures from what this section originally said**, all of them
things the writing found out:

**There is no eviction, and this is a store rather than a cache.** The
section asked for "a size or age cap". Measurement retired it: a thumbnail is
about 15 KB, an avatar about 150 KB, and Twitch serves at most 100 archives
per channel, so a channel streaming three times a week for five years reaches
roughly 12 MB. Any cap worth setting would never fire — a mechanism guarding
an event that does not happen and is therefore never exercised. Images are
**owned** instead: §7.3 deletes a channel's images when it deletes that
channel's history. `URLCache` was considered for the same job and rejected —
it honours `Cache-Control` and the system may purge it, so bytes whose whole
requirement is outliving their source cannot be built on it.

**`ImageStore` lives in `OxbowKit`, not the app target §8 named.** `swift
test` carries the coverage gate, and an actor with an injected fetch over a
temporary directory is fully testable there. Only `ChannelAvatar` is in the
app target.

**The avatar rides `profile(forLogin:)`**, which replaced
`displayName(forLogin:)` — the one request already paid when a channel is
added. Per-sweep traffic is unchanged. The consequence is that **a watch
added before this stage has no avatar and nothing backfills it**: re-adding
the channel is the only way to pick one up.

One measured constraint is now pinned by a test: `profileImageURL` accepts
any width and returns a URL built by interpolation, but the CDN serves only
28, 50, 70, 150, 300 and 600 (`docs/twitch-channel-api.md` §9.2). The request
uses 300 and must never be computed from a layout constant.

### 7.2 The pane — done

The view from the mockup, fed rows and cached images.

**Its rows carry state derived from the sweep joined against the queue's
`Job`s, not from a store.** This is the stage's one piece of scaffolding and
it is deliberate: `seen` alone cannot feed this view — a bare id has no
title, date or path — so a pane built on it could render only the `new` half
and every green check would be mock. Finished jobs carry both a title and
their delivered files, so joining the sweep against the queue's jobs is
meant to produce *real* `queued` and `downloaded` rows. The cost of the
shortcut is that this state is **not durable**: it exists only for as long
as the job it was joined against does. Remove a finished job — an entirely
ordinary thing to do to a queue — and the row it backed loses its history
along with it, reverting to whatever the sweep and the filesystem can still
say about it on their own, and leaving the list altogether if the archive is
already marked seen. Stage 3 replaces this join with the history store
precisely so that a row's past stops being a lease on somebody else's
cleanup.

**That claim was false in the shipped build.** `WatchPoll.sweep` returned
`watch.findings(in: archives)` — every archive already in the watch's `seen`
set filtered out before the join above, or anything else, ever saw it. Every
path that downloads an archive writes `seen`, so a completed download was
deleted from the data on its way to this pane, and no rule downstream could
recover an archive that was never handed over. Measured against the author's
own data before the fix: a channel with four archives and two downloaded
swept as two; a channel with two archives, both downloaded, swept as none,
and rendered as an empty channel, permanently. The filter now lives with the
two consumers that actually want it — `WatchPoller.actOnFindings`, deciding
what the unattended path may still submit, and `FindingAnnouncement.decide`,
deciding what to announce — and the sweep hands over everything it fetched.
`WatchPollResult.findings` is renamed `archives`, because the old name was
the lie that let a producer-side filter and this pane's own display filter
pass for the same thing.

Worth stating plainly: stage 2's own review could not have caught this.
Every task implemented its brief faithfully — the join above, the row-shown
rule below, the finished-job exception below that — and none of it was
wrong on its own terms. The defect sat one layer above all of it, in a
producer neither this pane's tests nor its review had reason to open. It is
also why the regression test that pins this has to actually run
`WatchPoll.sweep`: a test that hand-builds a `WatchPollResult` and feeds it
straight to the pane exercises the join correctly and passes against the
broken producer exactly as well as the fixed one — checked by reverting the
filter and watching exactly one of the two tests fail.

**A row is shown when the queue holds an unfinished or `.done` job for the
archive, or when the archive is neither seen nor dismissed.** The pane first
shipped showing only the second half — `Watch.findings(in:)`, "not in
`seen`" — which made every state above unreachable, because every path that
creates a job also writes `seen`: `WatchingModel.markSeen` for a manual Add
or Ignore, `WatchPoller.markSubmitted` for an automatic one. A row
disappeared at the exact moment it became `queued`. `add` queues first and
marks seen second, so an archive is momentarily both dismissed and queued;
the job has to outrank the dismissal as well as `seen`, or the one transition
this pane exists to show is the one it blinks through.

**Not any job — a finished one that is `.failed` or `.cancelled` does not
hold a row open.** An earlier version of this rule counted any job at all,
which meant a `.failed` or cancelled job — both finished, neither still
producing anything — outranked a person's own Ignore: `markSeen` persisted
the write, but the row stayed on screen with nothing telling anyone why, and
a cancelled job on an already-dismissed archive resurrected it as a fresh
Add. `.done` still counts, because that is what keeps `.downloaded`,
`.missing` and `.unverifiable` reachable once the job that produced them
stops running; `.failed` and `.cancelled` do not, the same rule
`AutoDownloadObserver` and `ArchiveRowState.state` already keep — a
cancellation is a person saying no. The accepted cost: a `.failed` archive
that has been ignored no longer renders at all, because Ignore now actually
works on it. A `.failed` archive that has *not* been ignored still renders as
`.failed`, because it is neither seen nor dismissed.

An archive that is seen with no qualifying job stays hidden — ignored, seeded
past (§3.2), or a download whose job has been cleared out of the queue (or
failed, or was cancelled). That is right for this stage: §5.2's filter is
what surfaces those, once §7.3's store can say which of the three any given
one was.

This is display only, and stays that way. Nothing here derives the seen-set
from the queue — §4 of `docs/design/channel-watching.md` still forbids that,
for the reason that still holds: a removed job would silently license a
re-download. Visibility is not the seen-set: losing a job costs a row its
place in the list, and never costs an archive its record of having been
acted on. What the join *does* decide is a row and a badge. `unreadCount` counts
only rows still waiting on a person to act — state `.available` — and nothing
else. Counting `queued` and `downloaded` rows into it would produce a badge
that never reaches zero, which is worse than no badge at all: the one thing a
count like this has to do is go away when there is nothing left to do.

**Reading the queue is not free, and the pane rebuilds only on the facts it
uses.** `QueueEngine.publish()` is un-debounced and fires on every helper
status line, so a running download changes `QueueController.jobs` hundreds of
times a second. Rebuilding on each of those meant a synchronous read of
`watches.json` on the main actor at that rate, a filesystem probe per
delivered file, and — since a rebuild also clears the pane's failure banners
— a refused Add explaining itself for less than a frame. `WatchingModel
.updateJobs` compares which archive each job is for, its status, and where a
finished one delivered, and does nothing when those are unchanged. A
percentage is not news to this pane.

**A live row is offered to a person, not withheld from them.** §5.2 of
`channel-watching.md` says a live broadcast may be shown, clearly marked, for
a human to choose, and only the unattended path refuses one — so the row's
badge stays a label rather than a button, and Add… and Ignore stay reachable
under right-click. What "may this be taken unattended" means is asked of
`ChannelArchive.isDownloadable` rather than re-derived here, so a status
Twitch introduces later cannot read as offerable in this pane while
`AutoDownloadPolicy` declines it; the cost is that such a status borrows the
word Live.

**The filter (§5.2) and the coverage counter (§5.3) are not built.** Both are
deliberately deferred to stage 3, and for the same reason: both need history
that does not exist yet. The filter's job is to reveal `ignored`, `skipped`
and missed entries that this stage never records — a row demoted out of the
queue leaves no trace for it to reveal. The counter's denominator is
"entries recorded since you started watching", and there is nothing recorded
here to count; a fraction built on the queue's transient jobs would shrink
and grow with cleanup rather than with what the channel has actually
produced, which is exactly the kind of lying number §5.3 already warns
against for the disconnected-volume case. Neither is worth building against
scaffolding that stage 3 replaces out from under it.

**§4.2's channel-level notice was pulled forward into this stage, ahead of
its own plan.** The per-row `unverifiable` badge (§4.1) already carries the
volume's name, but only in a tooltip — something a person has to think to
hover, on a row they may not even be looking at. "Your library might be
gone" is not a fact that belongs behind a hover. So `ChannelCard` derives it
itself, at the channel level, from the same rows the badge already has, and
states it as a sentence rather than leaving it to be found. It needed nothing
from the store §4.2 originally implied it was waiting on — only the rows this
stage already produces — so there was no reason to make a person wait for
stage 3 to see it.

Building the view before the store is the right order because **the store
exists to feed the view**. Its schema should be discovered from what the pane
turns out to need, not guessed and then found wanting.

#### 7.2.1 §4.1 was measured on real hardware

Stage 3 leans on §4.1's three-way rule harder than on anything else in this
document — the store's entire claim about what a person has rests on the
join never mistaking "the drive is gone" for "the file is gone" — so it was
worth checking against an actual unplugged disk rather than trusting the
theory of `nearestExisting` a second time.

A USB SSD mounted at `/Volumes/Storage` was force-unmounted while a file
remained recorded at `/Volumes/Storage/oxbow-check/a.mp4`. After unmount,
`/Volumes/Storage` does not exist, while `/Volumes` does.
`ArchiveRowState.FileAnswer.resolve` returned `.unknown(volumeName:
"Storage")` — correct.

The same measurement shows why the first implementation was wrong: it
resolved through `VolumeSpace.nearestExisting`, which walks *up* to the
deepest existing ancestor — `/Volumes`, on the boot volume — so it never
returned nil and would have answered `.absent`, offering to re-download a
drive's entire contents while the drive sat in a drawer.

### 7.3 The store

Replaces §7.2's derivation. Also owns image deletion: when a channel's
history goes away, its images go with it — see §7.1 for why that is the
cleanup rule rather than eviction. Rows stop being tied to the queue's lifetime,
history survives job removal, the counter's denominator becomes real, and the
filter gets something to reveal. Carries §3.2's migration, and gives the image
cache a real eviction rule.

---

## 8. Shape

- `ChannelHistory` (`OxbowKit`) — the entry, the state machine, and the
  transitions. Pure.
- `HistoryStore` (`OxbowKit/Persistence`) — its own file, mirroring
  `WatchStore`.
- The join (`OxbowKit`) — a pure function of an entry and what the filesystem
  answered, returning a row state. Takes the answer, never asks for it, so it
  is tested without a disk.
- `ImageCache` (app target) — fetching and eviction.
- The pane (app target).

`AutoDownloadObserver` grows a second job. It already watches submitted jobs to
a terminal status so a failure can be filed back as a finding; it now also
records the delivered path on success. That is the only place a `downloaded`
entry can be created honestly, because it is the only place that knows where
the file landed.

---

## 9. Not in scope

- **Playing video in Oxbow.** Reveal in Finder and open with the default
  player. A media player is a different application.
- **Managing the library** — renaming, moving or deleting files from inside
  Oxbow. The filesystem is the authority here precisely so that Finder stays
  the tool for that.
- **History for anything not from a watched channel.** A one-off download from
  intake has no channel to belong to.

---

## 10. Rejected

### 10.1 Following files by bookmark

macOS bookmark data would track a file across renames and moves, and Oxbow is
not sandboxed so nothing prevents it. Rejected because it makes the app's
claim about your disk into a guess that is usually right: the row would keep
its green check while pointing somewhere you did not put it. "Break honestly"
is the same choice made throughout this feature — a wrong claim about a file
you have is worse than an honest report that it is not where it was left.

### 10.2 Pruning dead entries

Dropping entries that are expired and absent keeps the file small, at the cost
of silently rewriting history — and the counter's denominator would shrink
under you, so coverage would change without anything having happened. They are
a few dozen bytes each. Keep them and hide them.

### 10.3 Deriving history from the queue permanently

§7.2 does this as scaffolding and §7.3 removes it. Kept out of the final design
because a queue is a work list, not a record: removing a finished job is a
normal thing to do, and it must not erase the fact that you downloaded
something.
