# The video record

**Status:** design, written 2026-09-09. Not implemented.

`docs/design/channel-watching.md` built the watcher.
`docs/design/channel-history.md` gave a watched channel contents, and its §3
proposed a per-channel store to hold them. This replaces that proposal with a
general one: **one record of every video Oxbow has touched**, whatever brought
it in. Channel history becomes a reading of that record rather than a store of
its own. Where §3, §4.2 and §6 of that document disagree with this one, this
one is later and wins.

Every claim about Twitch's API is measured in `docs/twitch-channel-api.md` and
`docs/twitch-metadata.md` rather than argued here.

---

## 1. The problem, stated as a person meets it

**Get Info on an expired VOD tells you almost nothing.** Open it on a download
that finished months ago and the card is a grey rectangle with a title.
`JobInfoWindow.loadMetadata()` re-fetches from Twitch on every open
(`QueueController.fetchInfo(for:)`, which shells out to the CLI's `info`
verb); when Twitch no longer has the video, the fetch fails and the window
falls back to `VideoCard(.unavailable(title:))`. The job's title survives only
because it was derived from that metadata back at intake and written into the
job. Everything else — the date, the duration, the thumbnail — is gone.

This is backwards. The one video you are guaranteed to still care about is the
one you kept, and it is the one the app can say the least about.

**And the same video renders differently depending on which pane you found
it in.** The Watching pane holds real metadata for every row, fetched by the
sweep. The queue holds a job. Get Info is keyed by `JobID`, so it can only be
opened on the second — a watched archive you have not downloaded is not
addressable at all.

Underneath both: metadata is fetched constantly and kept never. The sweep
fetches a channel's archives on every poll and discards them.
`ArchiveSubmission` runs the CLI's `info` verb once per archive on its way to
the queue and discards that too. The app has held the answer in memory dozens
of times and written it down zero.

---

## 2. What this delivers

**One row per video, and it outlives the video.** Title, date, duration,
qualities, thumbnails and the raw payload they were parsed from, captured the
first time Oxbow saw the video and kept after Twitch drops it.

**Get Info keyed by the video, not the job.** The same window from the queue
and from a watched channel, showing the same card, because it is reading the
same row. A job becomes a *section* of that window when one exists rather than
the thing the window is about.

**⌘I, not double-click.** The gesture is already bound for jobs in the menu
bar (`QueueActions.swift:127`); this finishes it rather than inventing
something.

**The filesystem still decides what you have.** Unchanged from
`channel-history.md` §4, with one correction in §5.2 below.

---

## 3. The record

A store of its own: `videos.json`, beside `watches.json` and the queue in
Application Support. Structurally identical to `WatchStore` and `QueueStore` —
same versioned envelope, same version probe read separately from the body,
same atomic replace, same set-aside recovery — because a fourth idiom for
"read a JSON file that might be from the future" is a fourth thing to get
wrong.

**Separate from `watches.json` for the reason §3 of `channel-history.md` gave
and still holds.** That file is small, hot and contended by three writers, and
the ordering discipline between them has already produced eight bugs of one
shape. This one is append-mostly and read by everything.

### 3.1 One row per video

Keyed by Twitch's video id — the string `JobInfo.sourceIdentifier` already
produces and `ChannelArchive.id` already is. That they are the same string
today is what makes this whole design cheap.

| Field | Source | Why |
|-------|--------|-----|
| `id` | both | The join key to everything. |
| `login` | §3.4 | Which channel produced it. Nil until resolved. |
| `title`, `duration`, `publishedAt` | both | So an expired video still renders. |
| `qualities` | `info` only | What it was available at, for a video that no longer is. |
| `categoryName` | both | What was being played. |
| `thumbnails` | both | Image-store keys, §6. |
| `deliveredPath` | the job | Where the download landed. §5 checks it. |
| `lastSeenOnTwitch` | sweep | Absent from the newest sweep means expired. |
| `payload` | `info` only | §3.3. |

### 3.2 Video facts and watch state are two halves

`skipped` and `ignored` are not properties of a video. They are statements
about your relationship to a *channel*: "this existed before you started
watching" and "you dismissed this from that list". A video you pasted by hand
has neither, and never will.

So the row above holds video facts only, and the watch state —
`new`/`skipped`/`queued`/`downloaded`/`ignored`/`failed`, exactly as
`channel-history.md` §3.1 defines them — hangs off it, written only for videos
belonging to a watched channel.

Get Info reads the first half and nothing else. That is what makes it render
identically no matter where a video came from, and it is the whole reason the
split is worth drawing.

`seen` still stops being stored and becomes derived, unchanged from §3.1:
*state is not `new` and not `failed`*.

### 3.3 The raw payload, stored verbatim and versioned

`VideoInfo.parse` reads a fraction of what the CLI emits. For a VOD, `info
--format Raw` writes three parts on stdout: a line of video-info JSON, a line
of **moments** JSON, and an m3u8 master playlist. Of those:

- the moments line is **not parsed at all**. Measured on VOD 2844787557: it is
  `data.video.moments.edges`, each node carrying `type` (`GAME_CHANGE`),
  `positionMilliseconds`, `durationMilliseconds`, `description`,
  `subDescription` and its own `thumbnailURL`. That is a chapter list with
  artwork. The VOD measured is a single-game stream and returned one moment,
  so the multi-entry case is inferred from the `GAME_CHANGE` type rather than
  observed;
- the m3u8 is read for `RESOLUTION` and `BANDWIDTH` only, ignoring the codec
  and framerate attributes on the same lines;
- the video-info JSON goes through `VideoInfoEnvelope`, which decodes five
  fields. Measured, the node also carries **`game`** (`{id, displayName,
  boxArtURL}`, the box art a `{width}x{height}` template), **`viewCount`**,
  **`description`** and **`status`** — all currently read by nothing.

Parse-and-discard freezes today's field set into the archive. A later feature
that wants chapter markers could have them for videos downloaded after it
ships and never for anything already kept — which is the opposite of what a
record is for.

So the payload is stored verbatim, in `payloads/<id>.txt` beside the JSON
rather than inside it, with the helper version that produced it recorded on
the row. **Measured at 3.4 KB** for the VOD above — against files measured in
gigabytes.

**The version stamp is load-bearing.** `VideoInfo`'s own doc comment is
explicit that `--format Raw`'s shape is not a stable upstream contract. For a
payload already captured that drift is harmless — it was written by a known
version — but only if a future parser can tell which. Unstamped payloads would
be a pile of documents in unknown dialects.

**Only `info` produces a payload.** A row first written by a sweep has none,
and gains one if and when the video is submitted (§7). A row that never gets
one is not defective; it renders from its parsed fields like any other.

### 3.4 Identity: the two sources name a channel differently

`ChannelFeed` keys on `login` — its archives query selects `id login` on the
user, and `Watch.normalisedLogin(_:)` enforces the alphabet. But
`VideoInfo.streamer` is `video.owner.displayName`
(`VideoInfo.swift:232`). Those are usually one word in two cases, and
sometimes unrelated: a display name can be Japanese while the login is ASCII.

Lowercasing a display name to get a login is exactly the "field that merely
correlates with what you want to know" trap `docs/twitch-metadata.md` §6 is
about. It must not be done.

**Measured 2026-09-09, helper 1.56.5, VOD 2844787557: it does.** The payload's
`data.video.owner` is `{id, displayName, login}` — the login is right there,
one field away, unread only because `VideoInfoEnvelope` never asked for it. So
`VideoInfo` gains a `login` and the GraphQL lookup this section was going to
need does not exist.

`owner.id` is there too, and is the more durable key — a login can be changed
by its owner, a numeric id cannot. Not adopted here, because `Watch` is keyed
on login throughout and re-keying the watcher is a separate change with its
own reasons. Worth knowing the option is available and costs one more field.

Until a login is resolved, `login` is nil and the row is simply not claimed by
any channel. It still renders in Get Info. This is a **degraded state, not a
failure state** — nothing blocks on it.

### 3.5 What earns a row

A **download** or a **sweep**, and nothing else.

Watched channels record every archive they see, because that is what makes
"what did I miss" answerable and what the `new`/`skipped`/`ignored` states
describe. Hand-pasted videos record on Add. Pasting a link and closing the
sheet leaves nothing behind.

The asymmetry is real rather than arbitrary: watching a channel is a standing
instruction to keep track, and pasting a link is not.

### 3.6 What is removed, and when

Rows are not removed by age, count, or the video expiring. They are a few
hundred bytes and deleting them is precisely what loses the answer to "what
did I miss".

Two things do remove:

- **Removing a watch** removes that channel's watch-state rows, and removes
  video rows that have **no `deliveredPath` and no job** — rows that were only
  ever "seen on Twitch". Rows for videos actually downloaded survive, because
  those are the ones Get Info exists to render.
- **Clearing the queue** removes nothing. A cleared job is not a statement
  about the video.

**Images are then expunged by an unreferenced scan** — one pass over the image
store, deleting anything outside the keep-set. This is why removing a watch has
to remove rows at all: with nothing ever removed, nothing could ever become
unreferenced and the store could only grow.

**The keep-set is both halves of what the store holds**, and getting this
wrong is the easy mistake: the surviving rows' thumbnails **union** the
surviving watches' avatars. One directory backs two kinds of image (§6), and
the record only knows about the first — a row names its thumbnails, and
nothing anywhere names an avatar except the watch itself. So "delete any
stored image no row names" is not the rule; read that way, un-watching one
channel declares every *other* watched channel's avatar an orphan and deletes
it. Nothing is lost forever — `avatarURL` is in `watches.json` and the next
draw re-fetches — but re-fetching is the thing this store exists to avoid. A
cold launch with the network down is supposed to still look like the design,
and after an un-watch it would not.

The union has to be assembled by a caller that holds both, because neither
half can see the other: the record has never heard of a watch, and the watch
list has never heard of a row.

The scale makes this relaxed rather than urgent. A thumbnail is about 15 KB
and an avatar about 150 KB against VODs measured in gigabytes; a few hundred
orphans would be unnoticeable. The scan is worth having because it is five
lines, not because anything is at risk.

---

## 4. Get Info

### 4.1 Two windows, one shared card

Get Info and intake want to show the same thing at the top — the frame, the
title, the date, the duration — and answer opposite questions underneath.
Intake asks *what should I fetch, and how*: a quality picker, trim, chat
toggles, a destination, an Add button. Get Info asks *what is this, and what
happened to it*: a status, steps, delivered files, Show in Finder.

They stay two windows sharing one component. `VideoCard` already is that
component and already has the three states this needs — `loading`, `loaded`,
`unavailable`.

### 4.2 Keyed by the video

`JobInfoWindow` becomes `VideoInfoWindow`, opened on a video id. The job
becomes a section, rendered when a job exists and absent when one does not.

This is what makes queue and Watching agree by construction rather than by
maintenance: there is one window, reading one row, and neither pane has a
private idea of how a video should look.

**A job with no resolvable video id stays addressable.** `JobInfo
.sourceIdentifier` is nil when a job carries no video, clip, or chat request
with an id. Rather than making that job un-openable, the window's key is a two
-case value — the video id when there is one, the `JobID` when there is not —
and the second case renders the job sections with no card.

### 4.3 What it says when there is no job

A watched archive you have not downloaded has a card, a date, a duration, a
category, and a line saying you do not have it. The way to get it is the row's
own Add action, which already exists and already queues directly.

**Get Info never starts a download.** It is the window you open to look, and a
window you open to look should not be able to commit you to twenty gigabytes.

### 4.4 ⌘I, and the selection it requires

⌘I is already Get Info for jobs in the menu bar — and it is already
selection-driven there: the button resolves a single selected id and disables
itself on any other count (`QueueActions.swift:118-127`). Extending it to the
Watching pane is consistency, and the queue is the precedent for how.

**It requires row selection in the Watching pane, which does not exist today.**
That is the larger half of the work and it is not optional: a keyboard command
with no selection model is a command keyboard and VoiceOver users cannot
reach. Selection also brings Return as the equivalent gesture, and gives the
context menu a defensible relationship to what is highlighted.

Double-click is deliberately **not** bound. Its only safe meaning here is
"open the file when there is one, otherwise nothing", which is a gesture whose
effect you must know a row's state to predict — and one that reads as broken
on the majority of rows.

---

## 5. The filesystem is the authority

Unchanged from `channel-history.md` §4: a `downloaded` row is a claim that a
file is at `deliveredPath`, and the claim is checked rather than trusted. The
record is advisory and the disk is authoritative. Deleting a download un-does
it — the row returns to being something you could fetch, as long as Twitch
still has it.

§4.1's three answers — `present`, `absent`, `unknown` — stand, and so does the
reasoning: collapsing "could not ask" into "the answer is no" is the mistake
that made `AutoDownloadPolicy` read a NAS with 8 TB free as a full disk, and
here it would make an entire library vanish from the view.

### 5.1 A row's path is its own

Because rows are now general, one channel's rows can sit on several volumes. A
VOD you pasted by hand into `~/Downloads` and a watch later pointed at a NAS
are two rows in one list with two homes, and neither has to be reconciled with
the other: `deliveredPath` is recorded at delivery, never computed from a
channel's current destination.

### 5.2 Which corrects `channel-history.md` §4.2

That section specified the disconnected volume as a **channel-level** state —
a banner naming the volume, with every row beneath it shown unavailable. With
mixed volumes that is wrong in both directions: it hides a file you can open
right now, and it implies a channel has one home.

**Reachability is a property of a path, not of a channel.** Each row asks
about its own volume; `VolumeSpace.nearestExisting` already answers per-path
and is the piece verified against a force-unmounted SSD.

The channel-level banner then says only what it actually knows and already
owns: *new downloads have nowhere to go* — `AutoDownloadPolicy.Reason
.destinationUnreachable`, which fires today. A channel can legitimately show
that banner while every existing row stays openable, and that is the honest
reading rather than a compromise.

The `4/20` counter (§5.3 there) inherits this: it counts per-row
reachability, and remains as provisional as that section says it is.

---

## 6. Images

`ImageStore` (shipped, stage 1) already does the work: keyed by SHA-256 of the
URL, never evicts on its own, owned by whatever owns the history. §3.6 above
is the deletion policy it was written to wait for.

### 6.1 Four frames or one, and why the difference is kept

A VOD's `info` payload carries **four** sampled preview frames; the sweep's
GraphQL carries **one**. `FilmstripThumbnail` cross-fades them and handles a
count of one correctly — "exactly 1 plays it straight" — so a single-frame row
renders as a still rather than breaking.

Levelling down to one frame everywhere would delete the filmstrip from intake.
Levelling up on the sweep would mean a subprocess per archive on every poll.
Neither is worth it, so the difference is kept and it is honest: an expired
video shows less because less was kept.

**Opportunistic upgrade, in one place only.** When Get Info opens on a
single-frame row whose video is still on Twitch, it fetches the full payload
once and stores it. Expired videos keep the one frame forever, because that is
genuinely all that was ever saved.

### 6.2 Avatar widths still come from the fixed list

Unchanged from `channel-history.md` §6, and still the trap most likely to
bite: `docs/twitch-channel-api.md` §9.2 measures that the CDN serves only 28,
50, 70, 150, 300 and 600, while the field accepts any width and returns a URL
built by interpolation. 100, 200, 400 and 1200 are 404s. The request is never
computed from a layout constant.

---

## 7. What writes it, and when

**The `info` fetch already happens on every submission.** This is the fact the
design turns on. `ArchiveSubmission.submit` does not build a job directly — it
routes every archive through `IntentSubmission.submit(...)` into an
`IntakeModel` (`ArchiveSubmission.swift:52`), which calls `await model.load()`
(`DownloadTwitchVideoIntent.swift:122`), which is `fetchInfo`
(`IntakeModel.swift:433`). It has to: that is how a watch's frozen quality cap
gets resolved against the renditions a particular VOD actually offers.

So a backfill of twenty archives runs twenty `info` subprocesses today,
sequentially, and discards all twenty results the moment each job is built.
There is no pre-step to add and no cost to bury. **The capture is a write on a
fetch that already happens**, at the one moment it is guaranteed to succeed —
while the video is still live and about to be downloaded.

| Trigger | Writes |
|---------|--------|
| Sweep finds archives | Rows for each: title, duration, publishedAt, category, thumbnail, `lastSeenOnTwitch`, `login`. Watch state `new`. |
| Submission (any of the three triggers) | Payload, qualities, four frames, `login` if unresolved. Watch state `queued`. |
| Job completes | `deliveredPath`. Watch state `downloaded`. |
| Job fails | Watch state `failed`. |
| Get Info on a live single-frame row | Payload, qualities, four frames. |

**A failed capture costs a thumbnail and nothing else.** No write here is
allowed to fail a download, fail a sweep, or mark a job failed. The `info`
fetch is already `try?`-shaped at its call sites and stays that way; a row that
does not get its payload is a row with fewer fields, not an error anyone sees.

This is also why the capture is **not** modelled as a queue `Step`.
`VideoInfoFetcher`'s doc comment states the existing rule — it produces no
artifact, has no place in the job model, and must never appear in the queue
list — and the rule is right. A step that failed would show a job as failed
because a JPEG did not arrive, and twenty of them would put twenty rows in the
queue for work nobody asked about.

---

## 8. What this does not do

**It does not reach backwards.** The record is only ever as complete as the
first moment Oxbow looked at a video. Anything downloaded before this ships,
or belonging to a channel never watched, is not in it and cannot be
reconstructed — its metadata is on Twitch or nowhere.

**Migration is a one-way trip and does not have to be pretty**, unchanged from
`channel-history.md` §3.2. Each id in `seen` becomes a `skipped` watch-state
entry with no video facts, because none were ever stored. Ids still on Twitch
pick theirs up on the next sweep. Ids already expired stay bare numbers
forever. `seen` is then no longer written, and nothing migrates back.

**Existing downloads get nothing retroactively.** A job in the queue right now
has no row. It gains one only if its video is submitted again or swept.

---

## 9. Testing

The pure parts carry the weight, as everywhere else in this codebase:

- **Store round-trip, version probe, set-aside recovery** — the same suite
  shape `WatchStore` and `QueueStore` already have.
- **The row's derived reading**: given a row, a job (or none), and a file
  answer, which of `ArchiveRowState`'s cases results. Already a pure function
  from stage 2; this widens its input.
- **Per-path reachability** (§5.2) with two rows on two volumes, one
  unreachable — the case that was specified wrongly and must not regress.
- **`login` resolution never guesses**: a display name that is not the login
  must leave `login` nil rather than produce a wrong one.
- **Payload capture is non-fatal**: a submission whose `info` fetch fails
  still queues its job.
- **Unreferenced image scan** deletes orphans and keeps referenced images,
  including one referenced by two rows.

Mutation-check the reachability and `login` tests specifically. Both encode a
distinction ("could not ask" ≠ "no", "looks like" ≠ "is") that a test can
appear to cover while passing against the wrong behaviour.

---

## 10. Staging

**Stage 3a — the store.** `VideoRecordStore`, the row, the two halves, the
payload directory, migration off `seen`. Writes from sweep and submission.
Nothing in the UI changes. Lands with the record filling up and nobody reading
it.

**Stage 3b — Get Info moves to the video.** `JobInfoWindow` becomes
`VideoInfoWindow`, keyed by the two-case value, reading the row and falling
back to a live fetch when there is no row. This alone fixes the expired-VOD
card in the queue, which is a visible win before any Watching work.

**Stage 3c — selection and ⌘I in Watching.** Row selection, Return, ⌘I, and
the context menu re-pointed at the selection. The largest UI piece and the one
most worth doing last, because the window it opens already works by then.

**Stage 3d — the per-path reachability correction** and the counter, if the
counter survives at all.

---

## 11. Open question

**Does the `4/20` counter survive?** `channel-history.md` §5.3 built it to be
deleted and put it at roughly even odds. Nothing here changes that.
