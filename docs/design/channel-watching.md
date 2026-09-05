# Watching a channel, and why it is a notifier first

**Status:** design, written 2026-09-04. Not implemented.

Every claim this document makes about Twitch's API is measured, and lives in
`docs/twitch-channel-api.md` rather than here. Where this document says the
API does or does not do something, that file is the citation and this one does
not re-argue it.

`docs/design/automation.md` §10.4 hands this project off explicitly, and names
the one piece it built that this needs: `QueueHost`.

---

## 1. What this delivers

**A watched channel**: Oxbow checks it for new archives, and tells you when
one appears. The finding lands in a durable list you can act on later, not
only in a notification you might miss.

**A per-channel promotion to automatic**: a checkbox, off by default, that
turns a watch from *tell me* into *fetch it*. Its settings are chosen when the
channel is added and are then that channel's, not the app's.

**A budget that cannot run away**: automatic downloading pauses itself when
disk gets tight or the destination goes missing, and pauses by falling back to
telling you — never by going quiet, and never by deleting anything.

**What it does not deliver** is a background agent. §5 argues from measurements
that it does not need one.

---

## 2. Why a notifier, and what the checkbox promotes it to

The feature exists because Twitch archives expire and a missed one is
unrecoverable. That is a real anxiety and nothing else in the app addresses
it: every other entry point makes downloading *faster*, and none makes it
*not-missed*.

But "download everything from this channel automatically" as the default
behaviour is a promise the app cannot keep safely. A multi-hour composite is
large, a channel produces them indefinitely, and the failure is silent until a
disk is full. So the default is the cheap half — find it, say so — and the
expensive half is something the user turns on per channel, having been shown
what it will cost.

### 2.1 The two states fail differently, and that asymmetry is the design

**Notify-only fails soft.** The poll misses a cycle, the list is stale, you see
it later and the clock is measured in weeks (§5.1). Nothing is lost.

**Automatic fails hard.** A wrong quality setting, an unreachable folder, or a
channel that streams more than expected, and the consequence is hundreds of
gigabytes or a job queued against a destination nobody chose. A job that fails
outright is worse still, because the archive is marked handled and expires
unnoticed — see §6.3.

Keeping the two visibly distinct — rather than treating automatic as a flag on
one uniform feature — is what makes every other decision here fall out. The
guardrails in §6.2 exist only on the automatic side. The demotion rule works
only because there is a safe state to demote *to*.

### 2.2 The inbox, because a notification is not durable

**A macOS notification cannot carry this feature.** It appears while you are in
a meeting, gets swiped away with forty others, and the archive expires anyway.
Delivering a *do not miss this* feature through a transient banner is
self-defeating.

So the notification is a pointer, not the product. What a find actually lands
in is a **durable list**: channel, title, duration, when it was published, and
Add / Ignore. The notification says how many are waiting and opens it.

Each row is one click from the intake window that already exists, prefilled —
so the notify-only path needs no headless composition at all. Only §6 does.

---

## 3. Adding a channel

Paste a channel URL or login. Oxbow fetches the channel's archive list and
shows what is there. Then three decisions, then Add. Structurally this is the
intake window with a list where `VideoCard` has one video.

### 3.1 Scope is chosen, not assumed

Two options, presented as a choice rather than decided for the user:

- **Only new.** Everything currently listed is marked as already seen, so
  nothing historical ever appears.
- **All available.** Nothing is marked, so everything currently listed becomes
  a finding.

**These are the same mechanism, seeded two ways.** Scope is not a stored mode
the poller consults forever after — it is only how §4's seen-set is
initialised at the moment the channel is added. After that first poll the two
choices are indistinguishable, and there is no second rule to keep consistent
with the first.

Neither is right often enough to be the rule. "Only new" silently discards a
VOD from yesterday that the user added the channel *because* they wanted. "All
available" hands someone twenty rows they did not ask for. Assuming either is
wrong about half the time, and the choice costs one control.

**"All available" must be worded as what it is.** The API caps a page at 100
and pagination is unreachable (`twitch-channel-api.md` §4, §5), so the honest
ceiling is *the newest 100 archives*. A control promising "all" and delivering
100 is a control that lies on exactly the channels where it matters.

### 3.2 The settings are frozen at add time

Destination, quality cap, output and chat size are seeded from `Preferences`
and then **copied onto the watch**. Changing global defaults later does not
rewrite what an existing watch fetches.

This is not the behaviour `IntakeModel` has, and the difference is not an
inconsistency. `reseedFromPreferences()` re-reads the store at every open
because an intake window *has* an open moment to re-read at
(`settings.md` §10.5 and the note under it). A watch has no such moment: it
fires months later with nobody present. Freezing is the only option that is
predictable, and the alternative — a preference change silently altering what
six channels download tonight — is the kind of action-at-a-distance this
repository has rejected everywhere else.

The consequence is that **the Watching list has to show each channel's
settings and offer an Edit**, or they become state nobody can audit.

**A quality *policy* is what makes this possible at all.** `settings.md` §3.1
rejected storing a rendition name because renditions differ between videos. A
watch pushes that further: it stores a preference for videos *that do not exist
yet*, where a rendition name is not merely unstable but unresolvable.
`QualityCap` is the reason this feature can be specified.

### 3.3 The backfill is priced before it is committed

"All available" plus the automatic checkbox is the one combination that can
queue twenty multi-hour jobs from a single click. It is not forbidden — it is
priced.

`SpaceEstimate` and `VolumeSpace` are in `OxbowKit`, so the sheet sums the
estimates across the backfill set and states the total against free space
before Add is enabled to do anything. That is what `#48` already does for one
job, applied to a set: **do not block the choice, make it informed.**

**Sum from the edges actually received, never from `totalCount`.**
`twitch-channel-api.md` §5.1 measured `totalCount` overcounting the returned
edges by up to two on channels small enough to verify. Every duration needed is
already in the response; using the count the API volunteers would mean quoting
a price for videos that cannot be fetched.

---

## 4. The seen-set is the watcher's own state

A watch has to remember what it has already handled, and **it cannot derive
that from the queue.**

`IntentSubmission.submit` already refuses a duplicate, but only against
*unfinished* jobs (`automation.md` §7.1) — deliberately, so a failed download
can be retried from a surface with no window. For a poller that guard is not
enough in two ways: a successfully downloaded archive is *finished*, so the
guard waves it through on the next poll; and `QueueEngine.remove(jobs:)` can
delete the job entirely, taking the evidence with it.

So each watch persists the set of archive ids it has acted on — queued,
ignored, or backfill-skipped alike. It is small (ids, bounded by what a channel
retains), it survives the queue being cleared, and it is the only thing
standing between a 30-minute poll and the same VOD every 30 minutes.

**Store it beside the queue, in the same shape.** `WatchStore` at
`watches.json` in the support directory, mirroring `QueueStore`: a `struct`
over a `fileURL`, atomic write, unreadable file moved aside as `.bak` rather
than losing everything. There is no reason to invent a second persistence
idiom for this.

---

## 5. Polling

### 5.1 No daemon, and the measurements are why

Coming from a server background the instinct is a launchd agent. It is not
warranted, and the reason is arithmetic rather than taste.

`twitch-channel-api.md` §6 measured surviving archives across seven channels:
the shortest window was 43 days, several sat at 58–60, two ran to months. The
clock this feature races is one to two *months*, not the two weeks the idea
started from.

Against that, **polling at launch and on a timer while running is sufficient.**
A user who opens Oxbow once a fortnight still catches everything. And the
workflow already keeps the app open: a composite runs for hours, so anyone
using this feature has Oxbow running a great deal already.

A background agent would buy coverage for exactly one person — the user who
goes six weeks without launching the app — and would cost a login item, a
System Settings entry, a second process, and the question of which process owns
`queue.json`, which `QueueEngine` will not share (see the `Window` comment in
`OxbowApp`). Menu-bar residency is the version worth revisiting if anyone asks;
an agent is not.

`QueueHost.shared.ready()` is how the poller reaches the engine, for the same
reason the intent does: it removes the assumption that a window came first.

### 5.2 A live broadcast must be skipped

`twitch-channel-api.md` §9.1 found that a stream in progress appears in the
list as a video with `status: "RECORDING"` — and it is the *newest* item, so it
is precisely what a "has anything appeared?" check finds first.

Queueing it downloads a partial broadcast whose chat is not final and whose
`lengthSeconds` describes only what had aired at the moment of the query.

**Anything unattended skips `status != "RECORDED"`** and picks the archive up
on a later poll once the broadcast has ended. The inbox may show it, clearly
marked, for a human to choose; nothing queues it on anyone's behalf.

The query is `type: ARCHIVE` throughout. Highlights and uploads are curated and
permanent — not at risk, not what a rescue feature is for, and numerous enough
(288 on one channel sampled) to make an unfiltered "download everything"
catastrophic.

---

## 6. Automatic downloading

### 6.1 It is a call to `IntentSubmission.submit`

`automation.md` §4 established that composition is not the problem: `IntakeModel`
already holds the intake's rules independently of any view, and the intent
drives it headlessly rather than extracting a composer out of it.

A watch does the same thing with its own frozen settings in place of the
intent's parameters. That reuse is the point — a second path that composed jobs
its own way would be a second path that drifts from the window's rules, which
is what §4 of that document rejected.

### 6.2 Demotion, not a budget, and never deletion

Backfill is finite and priced (§3.3). Ongoing automatic downloading is not:
watch a daily streamer for three months and it writes half a terabyte, one
individually reasonable job at a time.

**Not a budget.** A budget means tracking how much of the disk is *Oxbow's*,
which means tracking delivered files — and this app deliberately does not own
them (`QueueEngine.remove(jobs:)` never touches a delivered file). A ledger of
files the user is free to move, rename or delete is a ledger that is wrong
within a week.

**A free-space floor instead.** Automatic downloading stops when the
destination volume drops below a floor. **One floor, in Settings, not one per
watch** — free space is a property of a volume, and three watches pointed at
the same disk asking three different questions of it would be three answers to
one fact. One check against the
volume, no ownership model, `VolumeSpace` already does it, and it stays true
regardless of what else filled the disk.

**And it demotes rather than stops.** When the floor is hit, the watch falls
back to notify-only. It keeps polling, findings keep landing in the inbox, and
only the spending stops. The failure mode is "there is a list waiting for you",
which is the feature working — not silence.

**An unreachable destination demotes the same way.** A per-channel destination
makes "this channel goes to `/Volumes/Archive`" natural, and that drive will
not always be mounted. `Preferences` falls back to `~/Downloads` when a stored
destination does not resolve, which is right for a window a human is looking at
and wrong for an unattended watch that would deposit 15 GB somewhere nobody
chose. Two causes, one behaviour, one thing to explain and one thing to test.

**Never deletion.** For an app whose promise is that your VODs are safe on your
Mac, reclaiming space by deleting them is not a trade-off to weigh. It also
contradicts the guarantee that delivered files are never touched.

### 6.3 A failed automatic download becomes a finding again

The spec as first written said nothing about this, and three shipped behaviours
collide in the gap.

`resume.md` §8 makes retention **user-cleared**: a failed job holds its resume
directory until somebody dismisses it, and the failed row says so — "Failed —
26 GB held, dismiss to reclaim." That is honest when a person queued the job and
is looking at the queue. Under a watch, nobody is, so the bytes are held
indefinitely — and because they are held on the destination volume, they count
against §6.2's floor. A channel that fails systematically would therefore
convert its own watch to notify-only by exhausting disk, which is the right
outcome reached by entirely the wrong reasoning, and unexplainable to the user.

The sharper problem is that §4's seen-set marks the archive the moment it is
submitted. A failed automatic download is therefore **permanent**: the watch
never looks at that archive again, and it expires within weeks. The feature's
one promise is that you do not miss an archive, and the unattended path would
be the thing that loses one.

**So a failed automatic download returns to the inbox as a finding, marked as
failed.** The watch does not retry it. A person sees the row, and Add retries it
through the intake window like any other finding.

**Not an automatic retry**, with or without backoff. A VOD that fails for a
durable reason — subscriber-only, region-locked, removed mid-download — fails
identically every time, so a retry loop re-queues a multi-hour job every poll
forever, and backoff only slows the same wrong thing down. `resume.md` §8
deferred auto-retry deliberately; this does not un-defer it.

**A cancelled job is not a failure.** `JobStatus` treats `failed` and
`cancelled` alike as finished, but they mean opposite things here: a failure is
the app not managing something, and a cancellation is a person saying no. Only
`.failed` returns to the inbox. Re-offering something the user just cancelled
would be the app arguing with them.

**Not a special state, either.** A failed find is an ordinary finding wearing a
reason. It reuses the inbox, the notification, and the Add path that already
exist, and it degrades to exactly the state §6.2 demotes to. One safe state,
reached three ways: the disk floor, an unreachable destination, and a failure.

The job itself stays in the queue with its retained bytes and its failed row,
untouched by any of this. Reclaiming them stays a person's decision, exactly as
`resume.md` §8 specifies — this document adds a way to notice, not a new
policy about disk.

### 6.4 The floor belongs to the watcher, not to `submit`

`automation.md` §7 decided deliberately that the intent does **not** consult the
disk-space warning: the window shows it as a warning with a remedy and leaves
Add enabled, so refusing there would make two surfaces disagree about the same
job.

This document does not reopen that. The floor is a **watch-level policy applied
before submission** — the watcher declines to call `submit`, and `submit`'s own
behaviour is unchanged. A reader comparing the two documents should find a
watcher that chose not to ask, not a submission path that changed its answer.

---

## 7. What the API allows, and what it therefore forbids here

Three constraints from `twitch-channel-api.md` shape the UI directly, and are
repeated here only as consequences:

**No countdown.** There is no `expiresAt`; `deletedAt` is null until the video
is already gone; and retention does not follow from tier. The inbox shows
**"published 12 days ago"**, which is derivable and true. A countdown would be
invented.

**One page, one hundred.** Pagination is gated behind an anti-automation
challenge which this project will not attempt to defeat (§4 of that document).
Nothing in this design may require a second page — which nothing does, because
detecting new archives needs only the top of page one.

**A field that vanishes will surface as a null, not a build error.**
Introspection is disabled, so the schema is discoverable only by being wrong at
it. Every field the client depends on is pinned by a test against a recorded
fixture, and a parse that fails degrades the watch to a visible error rather
than to an empty list that looks like "no new videos".

---

## 8. Where it lives

A `NavigationSplitView` sidebar on the queue window, with **Queue** and
**Watching**, and an unread count on the latter.

Not a second window. The inbox and the queue are two moments in one workflow,
and a separate window is one you have to remember to go and look at — which is
the exact failure the feature exists to prevent. The sidebar also gives the
unread count somewhere to live, so "things are waiting" is visible without
depending on a notification.

### 8.1 A macOS 26 regression: `.badge()` before `.tag()` breaks selection

Building this sidebar's `List` hit a genuine SwiftUI bug on macOS 26: apply
`.badge()` to a row's label before `.tag()`, and clicking that row stops
changing the `List`'s selection binding at all. AppKit still fires — the row
highlights — but the value SwiftUI hands back to `selection` never updates.
Neither modifier's documentation says order matters, and nothing else in this
codebase's use of `.badge()` (§7.1 of `settings.md`, the menu-item icon
regression) is the same failure — that one is about auto-iconing menu items,
not about a `List` losing clicks.

Bisected by hand against the built sidebar, one row shape at a time:

| Row content | Click-to-select |
|---|---|
| `Text` alone, `.tag()` only | works |
| `Label`, `.tag()` only | works |
| `Label`, `.tag()` then `.badge()` | **broken** |
| `Label`, `.badge()` then `.tag()` | works |

The fix is the order, not the presence, of the two modifiers: `.badge()`
always before `.tag()`. `QueueView`'s sidebar carries an inline comment at the
call site recording this as load-bearing; this section is the place to look
for the reasoning and the bisection behind it.

---

## 9. Shape

- `ChannelFeed` (`OxbowKit`) — the GraphQL client. One query, `type: ARCHIVE`,
  `first:` bounded at 100, no pagination. Returns parsed archives or a typed
  failure. Testable against recorded fixtures, no network.
- `Watch` (`OxbowKit`) — channel identity, automatic flag, frozen settings,
  and the seen-set (which §3.1's scope choice merely seeds).
- `WatchStore` (`OxbowKit/Persistence`) — `watches.json`, mirroring `QueueStore`.
- `WatchPoller` (app target) — decides *when*, reaches the engine through
  `QueueHost`, applies §5.2's status filter and §6.2's floor, and either files
  a finding or calls `IntentSubmission.submit`. It also watches submitted jobs
  reach a terminal status, so a failure can be filed back as a finding (§6.3).
- `InboxModel` / `WatchingView` (app target) — the list, its counts, and the
  Add / Ignore actions.

The split follows the existing line: rules and persistence in `OxbowKit` where
they are tested without a window; timing and presentation in the app target.

### 9.1 What is tested

`OxbowKit` carries the coverage gate, so the testable decisions live there:
feed parsing against recorded fixtures including a `RECORDING` node and a
`totalCount` that overcounts; seen-set behaviour across a poll that finds
nothing, something, and something already seen; the demotion rule against an
injected `VolumeSpace` and an injected destination check; the backfill sum,
which must equal the durations of the edges received; and §6.3's rule, that an
archive whose job reached `.failed` is a finding again while one that reached
`.cancelled` is not — cancelling is a person saying no.

The views are verified by hand, as `development.md` records for the rest of the
SwiftUI layer.

---

## 10. Not in scope

- **Watching for clips.** A different connection, a different volume, and the
  expiry argument does not apply — clips do not expire.
- **Per-channel filters** on title, game or duration. Plausible, speculative
  before anyone has run a watch for a month.
- **Menu-bar residency and launch-at-login.** §5.1 argues they are not needed
  for this to be trustworthy. Revisit if users of the automatic half ask for
  coverage while the app is closed.
- **Retention or auto-deletion of downloaded files.** §6.2.
- **A notification preference.** `settings.md` §9 already places notification
  settings out of scope; this adds a source of them, not an answer.

---

## 11. Rejected

### 11.1 Automatic downloading as the default

The feature's whole value is not missing things, and the reflex is to make it
automatic. Rejected because the default has to be the state whose failure is
survivable (§2.1), and because a first run that queues twenty multi-hour jobs
teaches the user to distrust the feature permanently.

### 11.2 A background agent

See §5.1. It buys coverage for one user, and costs a second process contending
for state `QueueEngine` will not share.

### 11.3 Deciding the backfill scope on the user's behalf

Considered: always "only new" for safety, or always "everything, advisory".
Rejected in favour of asking (§3.1) — either rule is wrong about half the time,
and the question is cheap to put at the moment the user is already deciding.

### 11.4 A disk budget

See §6.2. It requires owning files this app deliberately does not own.

### 11.5 Deriving the seen-set from the queue

See §4. The queue forgets, by design and by user action, and a watcher that
forgets with it re-downloads what it already fetched.

### 11.6 Retrying a failed automatic download

See §6.3. A durable failure — subscriber-only, region-locked, removed
mid-download — fails identically every time, so a retry loop re-queues a
multi-hour job every poll and backoff only slows the same wrong thing down. The
failure goes back to the inbox and a person decides.
