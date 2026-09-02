# Defaults that stick, and the menus that reach them

Every download re-asks the same four questions: where does it go, what quality,
with chat or without, and how big is the chat text. The answers are almost
always the same, and the app has never remembered one of them across a launch.
There is no `Settings` scene, no `@AppStorage`, and no preference of any kind
beyond the update check's last-checked date.

This document covers the preference store, the two places that write it, and
the menu work that lands in the same menu — because Settings… joins `About
Oxbow` and `Check for Updates…` in the app menu, and all three currently have
a problem macOS 26 introduced.

---

## 1. What this delivers

**Four preferences that survive a launch**: destination, a quality *policy*,
chat on or off, and chat text size. Factory values are `~/Downloads`, Best
available, Video + chat, Medium — the values the intake already starts on, so
an app that has never been configured behaves exactly as it does today.

**Two ways to set them.** A `Make these settings my defaults` checkbox in the
intake, which captures a decision the user is already making; and a Settings
window, which is the only way to see or change them without starting a
download.

**Icons on the five menu items that lack them**, which is not decoration — see
§7.

**What it does not deliver** is a second source of truth. The checkbox and the
Settings window write one store, and the intake reads that store and nothing
else.

---

## 2. Where a default gets set

### 2.1 The intake panel

The intake's download options move into a collapsing panel alongside the
existing Trim disclosure, with a checkbox at the bottom:

```
⌄ Download Options
    Download        Video + chat  ⌄
    Quality         Best available  ⌄
    Chat text size  Medium  ⌄
    Save to         Downloads      Choose…
    ☐ Make these settings my defaults
```

The panel is where the user is already deciding these things for a real video.
A Settings window alone would put the deliberate act somewhere most people
never go, which means the defaults stay factory forever and the feature does
nothing.

### 2.2 The checkbox is unchecked, always

Including the first run.

This is the whole design. A checkbox that stays ticked is last-used-wins with
extra steps: every subsequent Add silently overwrites the defaults, and a
folder chosen once for one video becomes permanent — which is exactly what
`IntakeModel.defaultDestination`'s comment refused, and refused for the right
reason.

Unchecked-always has a second property worth more than it looks: **the
checkbox never has to be read.** An unticked box makes the same promise every
time, so nobody has to remember what state the app was left in. A box whose
meaning depends on history is a box people learn to distrust.

The cost is real and accepted: this is true opt-in, so a meaningful number of
users will never tick it. That is what makes the Settings window load-bearing
rather than a convenience (§5), and what makes the factory values obliged to
be good on their own.

### 2.3 Saved on Add, after the enqueue succeeds

Not on toggle. Cancel discards, which is what a Cancel button means.

Specifically: after `composedTemplate()` returns a template and the enqueue
happens. `addFailure` is the path where Add refused and the window
deliberately stays open; writing preferences there would persist the settings
of a job that never existed.

### 2.4 `hasSavedDefaults` has two writers and one meaning

A stored flag, not an inference. Someone can deliberately save defaults
identical to the factory values and must still be treated as configured —
comparing values against factory would call them a first-timer forever.

Editing any value in the Settings window sets it, exactly as ticking the box
does. The flag means *the user has expressed a preference*, not *the checkbox
was used*. Without that, someone who configures everything in Settings is
still greeted by an expanded panel that thinks it is teaching them.

### 2.5 The panel's expansion is its own persisted preference

Seeded expanded, and **saving defaults collapses it once** — the visible payoff
for opting in, tied to an explicit act, so it reads as cause and effect rather
than as the app moving furniture. After that it is whatever the user last left
it.

Deriving expansion from `hasSavedDefaults` instead is the tempting version and
it is wrong: someone who never opts in gets the panel forced open on every
launch with no way to stop it, which turns *informative* into *nagging*. One
persisted bool, always under the user's control.

### 2.6 The collapsed header summarizes

`⌄ Download Options` collapsed says nothing about where the file is going or at
what quality, and collapsed is the steady state — so that is most downloads.
The header carries the answer:

```
› Download Options — Video + chat · Up to 1080p · Downloads
```

The first person burned without this is someone whose saved destination is an
external drive they have since unmounted (§4.2). A summary is what makes the
collapsed state safe to leave collapsed.

**Not every warning gets that cover, so not every warning lives inside the
panel.** `IntakeModel.destinationFellBack` (§4.2's own warning) stays inside
the `DisclosureGroup`: the summary above is a real mitigation for it, because
it names the folder Oxbow actually used, not the one that vanished. The disk
space warning (`IntakeModel.spaceWarning`, `docs/design/disk-preflight.md`
§2-3) has no such cover — the summary carries output, quality cap and folder,
nothing about what is free — so it renders in the panel `Section`'s own
footer, outside the `DisclosureGroup`, visible whether the panel is open or
collapsed. It does not join `chatProblem`/`compositeProblem` in forcing the
panel open either (§2.7): it is advisory and does not gate Add, so nothing
about it demands the drawer itself, only that it stay visible. Moving it back
inside the panel silently reintroduces the exact failure `disk-preflight.md`
§1 opens with, aimed at precisely the person §2.5 collapses the panel for.

The encode-duration note ("Chat is rendered in a column beside the video and
encoded into one file. This takes roughly as long as the stream itself.")
lives in the same footer, for the same reason. `.videoWithChat` is the
factory default, so the note explaining that a composite takes as long as
the stream itself has to survive the one place most downloads actually take
— collapsed, chat included — or nobody sees it until the queue has already
sat "in progress" long enough to look stuck.

### 2.7 A collapsed panel must not hide a refusal

Some videos cannot deliver what the default asks for. A clip carries no chat of
its own — it is reconstructed from the broadcast it was cut from — so once
Twitch expires that broadcast there is nothing to download, and
`IntakeModel.chatProblem` refuses. `compositeProblem` refuses for the adjacent
reason when Twitch never recorded a rendition's pixel dimensions.

Both already exist, both already say which of the two outputs still works, and
**both render inside the download-options group** — the group this document
just put in a drawer that is closed by default. Add would grey out with the
explanation sealed inside it, which is word for word the failure the comment on
that view says it exists to prevent.

Defaults also make this more common rather than merely more visible. Reaching
`chatProblem` used to require deliberately choosing `Video + chat` for a clip;
with a saved default everyone reaches it without deciding anything. That is the
same escalation `chatProblem`'s own comment records for when `.videoWithChat`
became the initial value in `docs/design/compositing.md` §3 — one step further
along.

**The panel expands itself whenever either refusal is showing**, transiently.
The control that resolves it is inside the panel, so opening the panel is the
remedy as well as the warning. This never writes the expansion preference
(§2.5): it is a fact about this video, not a choice about how the user works,
and a clip with an expired broadcast must not permanently reopen the drawer.

**And `output` is excluded from a save while `chatProblem` is showing** —
exactly the shape of §3.7, for exactly the reason. Switching to `Video` here is
a workaround for one clip's defect, not a statement of preference. Without this
rule, a single tick of the checkbox on an expired clip turns chat off for every
future download, permanently and silently — the feature's own worst outcome,
reached by using it as intended. The other three fields save normally and the
footnote says which one did not.

Someone who genuinely wants a video-only default is not blocked; they set it in
Settings, or on the next video that has chat. That is a small price for
removing a trap that would otherwise be sprung by accident.

---

## 3. Quality is a policy, not a rendition

### 3.1 Why a rendition name cannot be stored

`IntakeModel.qualities` comes from the metadata of *this* video, and the names
are per-video strings: `1080p60`, `720p60`, `480p30-1`, `720p0-1`,
`1080p60-Portrait-1`. Some carry no resolution at all. There is no identifier
stable across two videos.

Storing the last-chosen name and matching by string is the cheap version, and
it degrades silently: pick `1080p60` once, paste a clip whose renditions are
named differently, get source with nothing explaining why. That is the same
silent-substitution failure `docs/design/chat-and-render.md` already records
the cost of.

So the store holds a **cap**, and the cap is resolved against each video.

### 3.2 The rungs

`Best available`, `Up to 1080p`, `Up to 720p`, `Up to 480p`, `Up to 360p`.

### 3.3 Two directions, and they are not inverses

**Resolve** (store → intake), when metadata settles: pick the highest rendition
whose `min(width, height)` (§3.6) is at or below the cap. If none qualifies, fall back to the lowest
available — a video that only offers 1080p should still download, not refuse.
When two renditions have the same short side, tie-break on bitrate (preferring higher);
when both are 0 (older clips), the tie degrades to first-listed.
`Best available` resolves to the empty string, which is today's behaviour and
already proven against the real CLI.

**Bucket** (intake → store), when the user picks a rendition: the largest rung
at or below what they chose.

These do not round-trip, and the design has to say so. A cap of `Up to 720p`
against a video offering only 1080p resolves to `1080p60`; bucketing that back
would save `Up to 1080p` and silently raise the user's standing preference
because of one unusual video.

**The fix is to keep the cap as first-class state, not to reconcile after the
fact.** `IntakeModel` holds both `qualityCap` (seeded from the store) and
`quality` (the resolved rendition for this video). Seeding sets the cap;
resolution sets the rendition; **the picker sets both**, deriving a new cap by
bucketing whatever the user chose. If the user never touches the picker, the
cap is untouched and saving writes back exactly what was seeded. No dirty flag,
no reconciliation — the preference-shaped value simply never stops existing.

### 3.4 Resolution skips what a composite cannot use

When `output` is `.videoWithChat`, resolve considers only renditions
`CompositeGeometry` can parse.

This matters because resolution writes a concrete name into `quality`, and
`compositeQuality` cannot tell a resolved name from a typed one — it honours
any explicit pick, deliberately and for good reasons documented on it. So a
cap that resolved to a dimensionless rendition would hand the user
`compositeProblem`'s dead end for a choice they never made.

Note what this does **not** change: an explicit pick of an unparseable
rendition is still honoured, and still produces `compositeProblem`. That
behaviour exists so a rendition is never silently swapped for a different one,
and it is correct. The rule here is narrower — the *ladder* never selects a
rendition the user did not name and cannot use.

### 3.5 Never round up

Bucketing takes the largest rung *at or below* the chosen rendition. `900p30`
becomes `Up to 720p`, not `Up to 1080p`.

Rounding up means a preference set from one video quietly produces larger files
than the user ever asked for, on every video after it. That is the wrong
direction for an app that spent `docs/design/disk-preflight.md` worrying about
running out of room. Below the lowest rung buckets to `Up to 360p`.

### 3.6 Bucket on the smaller dimension

`1080p60-Portrait` has resolution `1080x1920`. Its height is 1920 and its
`1080p` is the **width**. Bucketing on height would file a portrait clip as
`Best available`.

`min(width, height)` is the orientation-agnostic reading of the `p` number, and
it is what the name already means. `CompositeGeometry` is the existing precedent
for treating these dimensions carefully rather than trusting the name.

### 3.7 A rendition with no resolution saves the other three

The case `IntakeModel.compositeProblem` already exists for: Twitch does not
always backfill dimensions on an older clip's rendition, and that rendition
reaches the picker with an empty `resolution`. There is no size to bucket.

Save the other three fields, leave the stored cap untouched, and say which one
did not save. Blocking the whole checkbox over one unbucketable field would
punish the user for Twitch's metadata.

The same rule applies to chat text size, for a different reason: the picker
that sets it only renders while `output == .videoWithChat` (§2.1's mockup), so
once `.video` is selected there is no control on screen to have produced a
value worth saving. Saving whatever `chatSize` last held anyway would write
from a control the user cannot see and the checkbox's footnote never
mentioned — `IntakeModel.withholdsChatSizeFromSave` withholds it, saves the
other three, and the footnote says which one did not save, the same shape as
the unbucketable-quality case above.

### 3.8 The bucket is shown at the moment it is chosen

Ticking the box reveals a single line beneath it:

> ☑︎ Make these settings my defaults
> *Saved as **Up to 720p**. You can change these any time in Settings.*

The bucket note only appears when the pick is not already a rung, so the common
cases (`1080p60`, `720p60`, `Best available`) show only the second sentence.

Both halves earn their place. The first eliminates the entire class of "why am
I getting 720p now?" — a user who meant 1080 fixes it in one click instead of
discovering it three downloads later. The second is not really about telling
people Settings exists; it is about teaching that the checkbox and the Settings
window are **one store**, which is otherwise something you learn by being
confused.

---

## 4. Destination

### 4.1 One checkbox covers all four fields

Per-field save checkboxes would allow "save my quality but not this one-off
folder" and would look terrible. The situation is rare and the recovery is one
download away. One checkbox, four fields, stated plainly by its label.

### 4.2 A saved destination that no longer resolves

Unmounted volume, deleted folder, renamed parent. Checked **at seed time**, not
at Add: fall back to `~/Downloads` and say so inline.

Silently is not good enough here. `IntakeModel`'s disk-space preflight measures
the volume the destination sits on, so a silent fallback changes what the
estimate means without changing what it says.

The app is not sandboxed, so this is a path check and nothing more — no
security-scoped bookmarks, the same reasoning that lets `fileExists` probe the
user's chosen folder today.

---

## 5. The Settings window

`Settings { … }`, which gets ⌘, and the app-menu item for free.

One pane, four rows, and Restore Defaults. Destination as a path row with
Choose…, quality as the five rungs, chat as the same two-option control the
intake uses, chat text size as the existing three-way control.

The chat control is **not** a toggle, however much "chat on/off" invites one.
The store holds `DownloadOutput`, the intake renders it as `Video + chat` /
`Video`, and a Settings window rendering the same value as `Include chat ☑`
would be two vocabularies for one preference — the drift this document objects
to everywhere else. Changes write immediately — no Save button, which
is what a Mac preferences window does and what makes `hasSavedDefaults` fire on
edit (§2.4).

It is not a duplicate of the intake panel. They are two views on one store with
different jobs: the panel captures a decision already being made, the window is
the only place to answer *what are my defaults?* without starting a download,
and the only place to undo.

Notification behaviour and automatic update checking are deliberately **not**
here — see §9.

---

## 6. What this deletes

`IntakeModel.reset()` currently preserves `folder`, `output` and `chatSize`
across intake opens, with a paragraph explaining that those answer how the user
works rather than anything about this video. That instinct was right and this
document is its conclusion — but the mechanism was a within-one-run
approximation of a preference store, and now there is a real one.

`reset()` re-seeds all four from the store. The three-field carve-out and its
justification collapse into one line. `defaultDestination` stops being a static
fallback on the model and becomes the factory value of one preference, which is
the only place a factory value belongs.

---

## 7. The menus: a macOS 26 regression, not decoration

### 7.1 What the probe found

Run against the shipped 0.4.0 build on macOS 26, opening each menu and zooming
in.

**The symbols already render.** `Label(_, systemImage:)` inside `CommandMenu`
draws in both the menu bar and the context menu — no new API, no `NSMenuItem`
work. The Downloads menu has been shipping a full icon set since it was
written, invisibly, and it looks correct now. The context menu's
omit-when-inapplicable rule works alongside it: a completed job's context menu
showed Get Info, Show in Finder and Remove, with Retry and Cancel absent, while
the menu bar greyed them.

**But macOS 26 auto-icons system-provided items, and ours sit bare beside
them.**

- **Oxbow menu** — `Services`, `Hide Oxbow`, `Hide Others`, `Show All` and
  `Quit Oxbow` all draw icons. `About Oxbow` and `Check for Updates…` draw
  none. Both are ours, both are above the first divider, and they are the first
  things anyone opening the app menu sees.
- **File menu** — `Close` draws an ✕. `Add Download…` draws nothing. Two items,
  one iconed.

This is shipping today. It is not a feature we are adding; it is an
inconsistency the OS introduced under the app by giving system items icons and
leaving custom ones bare, and it will get worse the moment `Settings…` joins
the app menu as a third bare item.

**`eraser` renders as an outlined diamond.** At menu size it reads as no icon
at all — worse than absent, because beside Remove's clean minus-circle it looks
like a glyph that failed to load.

### 7.2 The symbol set

| Item | Symbol | Why |
|---|---|---|
| `About Oxbow` | `info.circle` | Deliberately reuses Get Info's symbol in a different menu. Both mean "information about this thing", and the alternative is a worse glyph chosen only to avoid a collision nobody sees. |
| `Check for Updates…` | `arrow.triangle.2.circlepath` | Means *check*. `arrow.down.app` is the update-available banner and would promise an update exists; `arrow.clockwise` is already Retry. |
| `Add Download…` | `plus` | Parity with the toolbar `+`, which is the same action opening the same window. |
| `Settings…` | `gearshape` | Verify first whether the `Settings` scene's generated item is auto-iconed like other system items. If it is, pass nothing. |
| `Remove Completed` | `text.badge.minus` | Replaces `eraser`. A list with a minus badge: entries leave the list. |

Everything already in Downloads stays as it is — `info.circle`, `folder`,
`arrow.clockwise`, `stop.circle` and `minus.circle` all render cleanly.

`text.badge.minus` is constrained, not chosen freely. The existing comment on
Remove explains why neither it nor Remove Completed may use a trash can:
removing a row deletes our workspace and leaves the delivered file exactly
where the user asked for it, and a trash can promises otherwise. Any
replacement inherits that constraint. `checkmark.circle` was the runner-up —
it names *what* is removed rather than the removal — and was rejected for
reading as "mark complete".

---

## 8. Shape

**`Preferences` and `QualityLadder` go in `Sources/OxbowKit`.** `Preferences`
takes an injected `UserDefaults`, the way `UpdateModel` already does; the
ladder's resolve and bucket are pure functions over `[StreamQuality]`. Both
land under the 90% coverage floor, which is the point of putting them there.

**Not `@AppStorage`.** It hard-codes `.standard`, which walks straight into the
`isUserSession` trap: `OxbowTests` is hosted by the app, so every
`xcodebuild test` would read and write the real `studio.lofti.Oxbow` domain.
That is the bug §9.2 of `docs/design/status.md` exists to remember, and an
injected `UserDefaults` avoids it by construction rather than by a guard
somebody has to remember to write.

**`IntakeModel` gains `qualityCap` and a `Preferences` collaborator**, injected
like `fetchInfo` and `volumeSpace` so seeding and saving are testable without a
window.

**`SettingsView` and the panel are thin.** Both render one store; neither owns
a rule.

### 8.1 What is tested

`Preferences` round-trips, factory values, `hasSavedDefaults` semantics under
both writers. `QualityLadder` resolve and bucket: exact rungs, the odd
rendition, portrait, the empty-resolution rendition, a single-rendition video,
an empty list, the documented non-round-trip in §3.3, and that resolution under
`.videoWithChat` skips a rendition `CompositeGeometry` cannot parse (§3.4)
while an explicit pick of the same rendition still reaches
`compositeProblem`. `IntakeModel` seeding,
the stale-destination fallback, and that `output` is withheld from a save
while `chatProblem` is showing (§2.7). What `saveDefaultsIfRequested()` itself
writes is tested directly; the ordering in §2.3 — that it is called only
*after* a successful enqueue, never on `addFailure` — is not, because that
call sits in `IntakeWindow.add()`, view code the coverage floor deliberately
does not reach (see "The views are not tested" below).

**The views are not tested, as usual.** The panel's expansion — including the
transient expansion in §2.7, and that it leaves the stored preference alone —
the checkbox's reveal, the collapsed header's summary and every menu icon are verified by hand.
The icons in particular can only be verified by opening the menus and looking,
which is how the problem in §7.1 was found in the first place.

---

## 9. Not in scope

- **Notification and update-check preferences.** Both exist as behaviour with
  no off switch, and both deserve one. They are a different subsystem with
  their own questions, and adding them here would turn one pane into a tabbed
  window before the first pane has shipped.
- **Chat colours, fonts, badges and overlay layouts.** Cut in
  `docs/design/compositing.md` §11 because upstream's renderer decides them.
  Unchanged by this.
- **Per-channel or per-link defaults.**
- **Remembering the last-used folder implicitly.** That is the thing §2.2
  refuses, not a follow-up to it.

---

## 10. Rejected

### 10.1 A checkbox that stays ticked

Last-used-wins wearing a checkbox. See §2.2.

### 10.2 Storing a rendition name

Silent degradation across videos. See §3.1.

### 10.3 Ladder rungs as the intake's own picker

Tempting, because it deletes bucketing entirely — what you pick is what gets
saved, one vocabulary everywhere.

Rejected because the picker's job is *what am I downloading right now*, and the
honest answer to that is a rendition with a real pixel size and a real size
estimate, which is what the picker shows today. A rung would have to display
its resolved rendition as subtext to be equally honest, at which point it is
the same information with an extra layer. Worse, `Up to 480p` against a video
that only offers 1080p would display a rung that is actively false.

The two questions are genuinely different and it is fine for them to have
different vocabularies, provided the translation is visible at the moment it
happens — which is what §3.8 is for.

### 10.4 Bidirectional write-back

Settings showing "what you last did". Rejected for the same reason as §10.1,
with the added problem that it makes the Settings window a display of history
rather than a statement of intent.

### 10.5 Live-applying a preference change to an open intake

Would need dirty-field tracking on every field to avoid overwriting what the
user just typed, to fix a situation that requires opening Settings while a
half-filled intake is up. Preferences take effect at the next reset.

That rejection is about the intake staying open while Settings changes
something out from under it — it says nothing about the far more ordinary
sequence: close the intake, open Settings, change a default, close Settings,
reopen the intake. `reset()` alone does not cover that either, because it
only fires `.onDisappear`, once per close — it reseeds the window for its
*next* video, not for its *next open*, and those are different moments
whenever Settings is what happened in between. `IntakeModel.reseedFromPreferences()`
is the fix: `IntakeWindow` calls it `.onAppear`, before the clipboard prefill,
so every open re-reads the store regardless of whether the previous close
already had. This is not the live-sync this section rejects — it never runs
while the window is open and a video is mid-flight, only at the moment a new
open begins, and it touches none of the fields a fresh video owns (link,
name, quality, trim, the checkbox) the way `reset()` does. No dirty-field
tracking is needed because nothing on screen is ever overwritten while it is
being looked at.

### 10.6 Per-field save checkboxes

See §4.1.
