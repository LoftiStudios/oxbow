# What a channel's video list will tell you, and what it will not

**Status:** written 2026-09-04, from a spike into whether Oxbow could watch a
channel for new VODs.

Every claim here was measured against the live endpoint on 2026-09-04, from
`curl`, with no client of ours in the way. Nothing is inferred from
documentation, because there isn't any — the same footing
`docs/twitch-metadata.md` is written on.

**Nothing here is shipped.** This document exists so that a design can cite
measurements instead of asserting them, and so the next person to consider
this does not re-run the probes. If channel-watching never ships, §4 and §6
are still worth keeping: they bear on the standing question of whether
`TwitchDownloaderCLI` could ever be dropped.

---

## 1. Why this document exists

Oxbow has never called Twitch's API directly. Every piece of metadata it holds
arrives through the bundled CLI's `info` verb, which takes one VOD id or clip
slug and returns one video's details. Nothing in the app, and nothing in the
bundled helper's five verbs, can answer *"what VODs does this channel have?"*

Watching a channel needs exactly that. So the question the spike asked was not
"how should the feature work" but "is the capability reachable at all, and on
what terms" — because a design written on top of an unverified query is a
design that finds out during implementation.

It turned out to be reachable, with two hard limits and one broken assumption.

---

## 2. The endpoint answers unauthenticated, arbitrary queries

```
POST https://gql.twitch.tv/gql
Client-ID: kimne78kx3ncx6brgo4mv6wki5h1ko
Content-Type: application/json

{"query": "query{user(login:\"ninja\"){id login displayName}}"}
```

That returns `{"data":{"user":{"id":"19571641",…}}}`. No OAuth, no persisted
query hash, no `Authorization` header. The `Client-ID` above is the Twitch web
player's own public identifier — embedded in twitch.tv's JavaScript, used by
every tool in this space including the CLI we bundle. **It is not a
credential, not a secret, and not ours.**

**An unknown login is not an error.** It returns HTTP 200 with
`{"data":{"user":null}}` and no `errors` key at all. Any caller must treat a
null `user` as "no such channel" rather than waiting for a failure that never
arrives.

---

## 3. The capability table

Measured on ninja (`19571641`) unless noted.

| What | Available | Notes |
|---|---|---|
| `user(login:)` → id, login, displayName | **Yes** | Null user for an unknown login (§2) |
| `videos(first:type:sort:)` first page | **Yes** | The whole feature rests on this |
| `first:` above 100 | **No** | Server-stated bound (§5) |
| `after:` — any pagination | **No** | Integrity-gated (§4) |
| `totalCount` on the connection | **Yes**, and unreliable | Overcounts what it returns (§5.1) |
| node: `id`, `title`, `lengthSeconds` | **Yes** | |
| node: `createdAt`, `publishedAt` | **Yes** | Identical on every archive sampled |
| node: `viewCount`, `broadcastType` | **Yes** | |
| node: `status` | **Yes** | `RECORDED`, and `RECORDING` for a live stream (§9.1) |
| node: `game { name }` / `game { id displayName }` | **Yes** | Both spellings resolve |
| node: `previewThumbnailURL` | **Yes** | Takes arguments — see §8 |
| node: `deletedAt` | **Yes**, and useless | Always `null` while the video exists (§6) |
| node: `expiresAt` | **No such field** | `Cannot query field "expiresAt" on type "Video"` |
| `roles { isPartner isAffiliate isStaff }` | **Yes**, and useless | Does not predict retention (§6) |
| Schema introspection | **No** | Disabled (§7) |

---

## 4. Pagination is integrity-gated, and we do not intend to defeat it

Any query carrying `after:` fails:

```json
{"errors":[{"message":"failed integrity check",
            "path":["user","videos"],
            "extensions":{"code":"IntegrityCheckFailed"}}],
 "data":{"user":{"videos":null}},
 "extensions":{"challenge":{"type":"integrity"}}}
```

**Reproduced four ways**, to rule out the obvious alternative explanations:
with and without `sort: TIME`; with an invented cursor and with one harvested
from the response immediately before; and interleaved with unpaginated
requests that kept succeeding throughout. It is not rate limiting, it is not
an expired cursor, and it is not a consequence of probe volume — it is the
`after:` argument specifically.

Twitch's integrity system is an anti-automation control. Satisfying it means
obtaining a `Client-Integrity` token through a challenge designed to be hard
for non-browsers to answer.

**Oxbow should not attempt it.** It is an arms race against a party that will
always be ahead, it puts the app on the wrong side of Twitch's terms, and — as
§5 shows — we do not need to. **Any design that requires a second page is the
wrong design.** That constraint is load-bearing, not incidental.

### 4.1 Upstream has no integrity handling at all

`TwitchDownloaderWPF`'s mass-download window (`WindowMassDownload.xaml.cs`)
pages by harvesting a cursor and passing it to `TwitchHelper.GetGqlVideos`,
which interpolates it into `after:`. Neither carries any handling for the
challenge, and neither does `TwitchDownloaderCore`.

**One false positive, recorded so the next person does not chase it.** A
case-insensitive search of the upstream tree does hit
`TwitchDownloaderWPF/Behaviors/WindowIntegrityCheckBehavior.cs`. It is
unrelated — a WPF attached-property behaviour that calls
`CoreLicensor.EnsureFilesExist` to confirm the app's *licence files* are on
disk. Nothing in upstream touches Twitch's integrity challenge.

So upstream's bulk-download pagination is, on this evidence, broken against
plain requests today. **The lesson to take from their implementation is which
wall they hit, not how they got past it** — they did not.

---

## 5. One page is enough, and the server says how big it is

`first:` is bounded, and the server states the bound rather than silently
truncating:

```
argument 'first' value must be between 1 and 100.
```

100 is plenty for both things a watcher needs:

- **Detecting new VODs** needs only the newest few. A watch stores the id or
  timestamp it last saw and diffs against the top of page one.
- **Backfill** fits too. 100 archives reached back to 2025-11-22 on ninja
  and 2026-03-16 on shroud — well beyond any retention window, on the two
  most prolific channels sampled. See §5.1 for what to size it from, which
  is not the number the connection offers you.

The practical ceiling is therefore *the newest 100 archives*, and any UI
offering "all available" must say so rather than implying completeness.

### 5.1 `totalCount` overcounts, so size a backfill from the edges

`totalCount` is **not** the number of videos the connection will hand you.
Measured against five channels whose whole list fits in one page — every one
returning `hasNextPage: false`, so nothing was being withheld for a page we
cannot reach:

| channel | totalCount | edges returned | delta |
|---|---|---|---|
| lilbadsnacks | 8 | 7 | 1 |
| wheelyf | 6 | 4 | 2 |
| day9tv | 29 | 27 | 2 |
| northernlion | 40 | 39 | 1 |
| vedal987 | 42 | 42 | 0 |

The gap is not explained by `status` — every returned node read `RECORDED`
except northernlion's single `RECORDING`, which *was* returned. Whatever the
surplus counts (purged but not yet dropped, subscriber-restricted, in
flight), it is something the caller cannot fetch and must not promise.

**A backfill estimate must therefore be summed from the `lengthSeconds` of
the edges actually received, never derived from `totalCount`.** That is both
exact and free — the durations are already in the response. Telling someone
"8 VODs, about 140 GB" and then queueing 7 is the kind of small dishonesty
that makes every other number in an estimate suspect.

### 5.2 The cursor is page-level, despite looking per-edge

Every edge in a page carries an **identical** `cursor`, encoding the page's
**last** node as `id|viewCount|createdAt|lengthSeconds`. For a four-item page
ending on video `2828044593`:

```
node 2862926638  cursor 2828044593|121826|2026-07-24T19:02:43Z|7132
node 2856555054  cursor 2828044593|121826|2026-07-24T19:02:43Z|7132
node 2850155378  cursor 2828044593|121826|2026-07-24T19:02:43Z|7132
node 2828044593  cursor 2828044593|121826|2026-07-24T19:02:43Z|7132
```

This is not the Relay convention, where a cursor addresses its own edge.
Recorded because it makes upstream's `edges.FirstOrDefault().cursor` correct
by accident rather than by design — and because anyone reasoning about
cursors here will otherwise assume semantics the endpoint does not have.

---

## 6. Retention is not derivable, and this broke an assumption

The spike began from the premise that VODs expire on a short, knowable clock,
and that Oxbow could show a countdown. **Both halves are wrong.**

There is no `expiresAt`. There is a `deletedAt`, but it is `null` for every
video that still exists — it can only tell you a video is already gone, which
is the one moment the information is worthless.

And the observed windows do not agree with each other. Oldest surviving
`ARCHIVE`, measured 2026-09-04:

| channel | tier | archives | oldest surviving |
|---|---|---|---|
| day9tv | partner | 29 | 59 days |
| northernlion | partner | 40 | 60 days |
| vedal987 | partner | 42 | 58 days |
| lilbadsnacks | partner | 8 | 43 days |
| wheelyf | **affiliate** | 6 | 49 days |
| ninja | partner | 1096 | ≥ 9 months |
| shroud | partner | 1554 | ≥ 172 days |

Three partners cap cleanly at ~60 days. Two, both very large, do not — by
more than an order of magnitude. A sixth partner sits at 43. `roles` is
queryable and reports every one of those six identically, so **tier does not
predict retention** and querying it for that purpose is a dead end. Recorded
so nobody re-explores it.

**The one non-partner sampled makes the point harder, not softer.** `wheelyf`
is an affiliate, and affiliate retention is commonly cited as 14 days — but
its oldest surviving archive is **49 days** old. Either the cited figure is
stale or it is not applied the way it is described. Whichever it is, we
measured it and it does not match, which is the entire reason this file
exists.

Note the caveat on the last two rows: 100 is the page cap, so "oldest
surviving" there is the 100th-newest video, not necessarily the true oldest.
That weakens the *lower bound* and not the conclusion — those archives are
demonstrably older than 60 days either way.

**What follows for any design:** a countdown is not honest and must not be
shown. "Published 12 days ago" is derivable, true, and nearly as useful.

The underlying urgency survives — every window measured is finite, and the
shortest of them is 43 days — but it is a clock of roughly one to two months,
not the two weeks this spike set out assuming. Anything paced against it can
be correspondingly relaxed, which is why a channel watcher does not need a
background daemon to be trustworthy.

**The sample is seven channels on one day**, six partners and one affiliate,
skewed toward the large. It is enough to disprove "retention is 14 days and
predictable from tier". It is not enough to assert what retention *is*, and
nothing here should be read as claiming a floor.

---

## 7. The schema is discoverable only by being wrong at it

```json
{"errors":[{"message":"GraphQL introspection is disabled"}]}
```

`__type` and `__schema` are both refused. Field discovery is therefore
trial and error against the error messages, which are at least specific:

```
Cannot query field "expiresAt" on type "Video".
```

The consequence for us is the same posture `docs/twitch-metadata.md` §7 draws:
**every field Oxbow depends on has to be found empirically and then pinned by
a test**, because there is no schema to diff against and no announcement when
one changes. A field that quietly disappears will surface as a null in
production, not as a build failure.

---

## 8. `previewThumbnailURL` takes arguments, and is a template without them

Asked for bare, it returns a URL with **literal placeholders**:

```
https://static-cdn.jtvnw.net/cf_vods/…/thumb/thumb0-{width}x{height}.jpg
```

Asked for as upstream does — `previewThumbnailURL(height: 180, width: 320)` —
it returns a concrete URL of the shape `StreamThumbnail` already handles.

**This is a live footgun for us.** `StreamThumbnail.rewritten(_:)` matches
`thumb\d+-\d+x\d+\.jpg`; the placeholder form fails that pattern, so a bare
request would flow an unusable URL straight through the rewriter unchanged and
into an image load that 404s. Two ways out, both fine:

- request `(width: 1280, height: 720)` directly and skip `StreamThumbnail`; or
- request `(width: 320, height: 180)` and rewrite as the intake does today.

The second keeps one code path for both sources and is probably preferable.
Either way the argument is not optional in practice.

---

## 9. `videos` mixes three broadcast types, and only one of them expires

`type:` accepts `ARCHIVE`, `HIGHLIGHT` and `UPLOAD`. Omit it and you get a
blend. On ninja:

| type | totalCount |
|---|---|
| ARCHIVE | 1096 |
| HIGHLIGHT | 288 |
| UPLOAD | 0 |

Highlights and uploads are curated and permanent — they are not at risk, and
they are not what a rescue feature is for. **`type: ARCHIVE` is mandatory, not
a refinement.** Omitting it would let "download everything from this channel"
reach for a back catalogue that has been sitting safely for three years.

For scale on what "everything" can mean: ninja's newest 100 archives total
**567 hours** of video.

### 9.1 A live stream appears in the list as a video

`status` is not always `RECORDED`. northernlion's list, fetched while they
were streaming, contained one node with `status: "RECORDING"` — a broadcast
in progress, already addressable by VOD id, still growing.

This is a trap for anything unattended. A watcher polls, sees a video it has
never seen before, and queues it — and what it downloads is a partial stream
whose chat is not final and whose `lengthSeconds` describes only what had
aired by the moment of the query. Worse, it is the *newest* item, so it is
exactly what a "has anything new appeared?" check finds first.

**Anything acting without a human must skip `status != "RECORDED"`**, and
pick the video up on a later poll once the broadcast has ended. A person
choosing from a list may reasonably be offered it, clearly marked, but
nothing should queue it on their behalf.

---

## 10. What this means for dropping the CLI

`docs/design/cli-dependency.md` prices each verb's replacement. This spike
touches that argument in one narrow place and complicates it in another.

**Narrowly:** `info` is the one verb that is pure API with no download logic,
and §2 shows its underlying query is reachable natively. Moving it in-house
would take a .NET process spawn out of the intake path.

**But:** §4 is evidence of how fast this surface moves, and in which
direction. Integrity checks guard pagination today; nothing says they stay
there. Doing this ourselves means Oxbow *owns* that fragility rather than
inheriting it from a project which — as §4.1 shows — has not kept up with it.
That is a maintenance transfer, not a maintenance saving, and it should be
argued on intake latency rather than on reducing our exposure.
