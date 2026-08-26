# Chat, render, and clips — design

**Status:** approved 2026-08-24, implemented 2026-08-24 on `chat-and-render`.

Implemented as designed, with three notes where reality was sharper than §3
and §6 anticipated:

- **`info --format Raw` emits two different documents, not one.** §3 describes
  only the VOD shape. A clip's output is a single JSON object under
  `data.clip` — no moments line, no m3u8 section, and no trailing newline —
  with its renditions inline at `clip.assets[].videoQualities`.
  `VideoInfo.parse` handles both and produces the same `VideoInfo` either way.
- **A clip's quality names come from upstream, verbatim — but the name is not
  what reaches `-q`.** `{quality}p{fps}`, `-Portrait` for a vertical asset,
  `-1`/`-2` for the repeats Twitch always returns. `name` stays exactly this,
  because it is what the picker displays and what disambiguates two
  renditions that would otherwise collide — a prettier name of our own would
  hand people the wrong video (see below) and call it a success.

  What changed since this was first written: **a trailing `-<digits>`
  disambiguation suffix does not resolve as `-q` at all.** Measured against
  the real bundled helper (1.56.5) on clip
  `BitterPoorLadiesNerfRedBlaster-MBUzt9WrmWvpraw3`, whose renditions include
  1080p60, 720p60 and 480p30:

  | `-q` argument | resolution actually downloaded |
  |---|---|
  | `480p30-1` | 1920x1080 (wrong) |
  | `480p30-2` | 1920x1080 (wrong) |
  | `720p60-1` | 1920x1080 (wrong) |
  | `480p30`   | 852x480 (correct) |
  | `720p60`   | 1280x720 (correct) |
  | `480p`     | 852x480 (correct) |

  Exit code 0, no warning, every time — it silently falls back to the
  highest rendition rather than failing loudly. Stripping the trailing
  `-<digits>` before it reaches `-q` is what makes it resolve.

  **A bare `-Portrait` name is not affected — but `-Portrait-<digits>` is a
  second, opposite trap, not just an exception.** `1080p0-Portrait` and
  `480p30-Portrait` both resolved to the correct rendition, unstripped. But a
  clip can also emit `1080p60-Portrait-1` — upstream's own per-asset
  disambiguation, not ours — and *that* name resolves correctly too, while
  the tidier `1080p60-Portrait` silently downloads the landscape file
  instead (byte-for-byte the same as `1080p60-1`). So `commandLineValue`
  cannot strip "any trailing hyphen-then-digits": it strips one only when
  what is left over is a bare quality name (`^\d{3,4}p\d{1,3}$`), which
  `-Portrait` and `-Portrait-<digits>` alike never are. The trap in that rule
  is `720p0`: the `0` there is the framerate, not a suffix, and there is no
  hyphen before it to match — stripping it would turn `720p0` into `720p`, a
  different (and possibly nonexistent) rendition. Identical duplicates are
  collapsed; the survivor keeps upstream's name.
- **The render options are bounds-checked**, the way §5's trim already is. A
  render is the second step of its job, so a `0` width reaches FFmpeg only
  after the chat download has finished.

Prerequisites: `docs/design/task-queue.md` (the engine and its templates) and
`docs/design/queue-ui.md` (the intake this replaces).

---

## 1. What this delivers

Paste any Twitch VOD or clip link, choose which of its outputs you want —
the video, the chat file, a rendered chat video — configure the render, pick a
folder, and go. Filenames are derived from the video's own metadata.

This is the slice that makes the bundled C# helper worth bundling.
`docs/architecture.md` §3.5 puts "reimplementing chat render in Swift" on the
do-not-suggest list because chat render is "the one part genuinely worth
keeping in C#" — and until now nothing in the app has rendered chat at all.

**Verified before designing.** Chat download and chat render were both driven
end to end with the exact argv `ArgumentBuilder` produces, against the real
bundled helper and our LGPL FFmpeg:

| Path | Result |
|---|---|
| `chatdownload` → JSON | `exited(0)` |
| `chatrender`, defaults | `exited(0)`, 350x600 @ 30fps, `encoder: h264_videotoolbox`, decodes clean |
| `chatrender`, sharpened | `exited(0)`, decodes clean |

That mattered because the render is where the licence constraints bite: the
CLI's default encoder is `libx264`, which is GPL and **absent from our build**,
and `--sharpening` appends GPL-only `smartblur`. Both workarounds are now
proven rather than assumed.

## 2. Intake

> **Note added 2026-08-24, after implementation; superseded 2026-08-25.** The
> three-toggle intake described here is what shipped first, but it has since
> been replaced: the intake now offers two choices, *video* or *video + chat*,
> with the standalone chat render removed. See `docs/design/compositing.md` §3
> for the current intake and `docs/architecture.md` §7, "Narrowing the intake",
> for the decision. Nothing below is wrong — it is the historical record of why
> the three toggles existed — it just no longer describes what is built. Read
> `compositing.md` §3 before building on the intake.



One sheet, in this order:

1. **Paste a link.** VOD or clip; the parser decides which.
2. **Oxbow fetches the video's info** and fills in a **name** field with
   `{streamer} - {date} - {title}`, editable.
3. **Toggle outputs:** Video, Chat, Render chat.
4. **Pick a quality** for the video, with estimated sizes.
5. **Choose a folder.** One choice, however many outputs are on.

Rejected: a job-type picker, and a menu of per-type sheets — which is what the
WPF app does, with five pages and the queue as a sixth you opt into. Oxbow is
queue-first by design (`architecture.md`), and the five templates are really
combinations of three outputs, so asking the user to name a template makes them
learn our taxonomy to express "this VOD, with chat".

### The Chat toggle answers an open question

`task-queue.md` §10 asks where intermediates go when a user wants to keep them.
`ChatRequest.destination` is already `URL?`, where `nil` means "stays in the job
workspace and is discarded with it".

So: **Chat on** sets a destination and the file is delivered. **Render on with
Chat off** downloads the chat purely as the render's input and discards it. The
toggle *is* the affordance; no new concept, and the queue already supports both.

## 3. Metadata

`TwitchDownloaderCLI info --id <id> --format Raw` emits, on separate lines: a
JSON object of video info, a second JSON object of "moments", then an m3u8
master playlist. We parse the **first line** as JSON into `VideoInfo`:

```swift
public struct VideoInfo: Sendable, Equatable {
  public var streamer: String     // owner.displayName
  public var title: String
  public var createdAt: Date      // createdAt, ISO-8601 UTC
  public var duration: Duration   // lengthSeconds
  public var qualities: [StreamQuality]
}

public struct StreamQuality: Sendable, Equatable {
  public var name: String         // "1080p60", "720p60", …
  public var bitsPerSecond: Int
  public var resolution: String
}
```

Qualities come from the m3u8 section's `EXT-X-STREAM-INF` lines
(`BANDWIDTH`, `RESOLUTION`, `STABLE-VARIANT-ID`).

**Two upstream defects found while designing, worth PRs.** `--format json`
throws `NotImplementedException`, which is why we parse `Raw`'s first line —
a fragile seam that a real JSON mode would remove. And `--format Table` prints
`07:34:51 UTC` where the raw payload says `19:34:51Z`, which looks like a
12/24-hour formatting bug. Neither blocks us; both are the kind of small,
broadly-useful fix `architecture.md` §8 favours.

This fetch runs **outside the queue**, at intake. It is not a step, has no
artifact, and must not appear in the queue list. `QueueController` invokes the
helper directly through `HelperProcess`; the helper path comes from
`AppComposition`, which already resolves it.

## 4. Filenames

Base name: `{streamer} - {date} - {title}`, then a per-output suffix:

| Output | Suffix |
|---|---|
| Video / clip | `.mp4` |
| Chat file | ` - chat.json` (or `.txt`/`.html` per format) |
| Rendered chat | ` - chat.mp4` |

`{date}` is the **local** date, converted from the UTC `createdAt`. A stream
starting 21:00 Pacific is already tomorrow in UTC, and the day the streamer and
the viewer both think it happened is the local one.

Sanitisation and truncation are one pure function, and the constraints are
sharper than they look:

- **`/` is illegal** in a macOS filename and `:` still confuses Finder. Both are
  replaced rather than stripped, so words do not run together.
- **APFS caps filenames at 255 *bytes*, not characters.** A title of emoji or
  CJK hits the cap in far fewer characters than a Latin one.
- **Truncation must be grapheme-aware.** Cutting at a byte offset can split a
  multi-byte scalar and produce invalid UTF-8, or sever a ZWJ sequence and turn
  one emoji into two unrelated ones. Truncate whole grapheme clusters.
- **The longest suffix has to be reserved**, or a job's video fits and its
  ` - chat.mp4` sibling does not — the two files must not disagree about their
  own base name.
- Trailing separators and whitespace left by truncation are trimmed, so a name
  never ends in `- ` or a dangling space.

Emoji are **kept**, not stripped. They are legal on APFS and they are part of
the title the streamer chose.

Collisions are the CLI's problem for the file it writes, but not for ours: the
engine moves onto an exact path and `QueueEngine.move` already replaces an
existing file. A user re-running the same job overwrites the previous result,
which matches `--collision Overwrite` in the workspace.

## 5. `JobTemplate` becomes a composition

**This is the one change to shipped, tested code, and it needs a decision.**

`JobTemplate` is an enum of five fixed combinations: `video`, `clip`, `chat`,
`chatAndRender`, `videoChatAndRender`. Mapping the toggles onto it, seven of
eight VOD combinations work and **video + chat without render has no case at
all**. Adding clips as a first-class media type multiplies the gap: `clipAndChat`
and `clipChatAndRender` are missing too.

Patching the enum means eight cases and growing combinatorially with every
future output. The toggles are three independent booleans; the model should say
so:

```swift
public struct JobTemplate: Sendable {
  public enum Media: Sendable { case video(VideoRequest), clip(ClipRequest) }
  public var media: Media?
  public var chat: ChatRequest?
  public var render: RenderRequest?
}
```

`makeJob` builds steps from whichever parts are present and wires `dependsOn`
from render to chat. Every previous case remains expressible, and the
seven-of-eight gap disappears because combinations are no longer enumerated.

The cost is real: `JobTemplate` is covered by existing tests, `Reconciler` and
`Scheduler` consume the jobs it produces, and this is a source-breaking change
to a type in the public library surface. It is proposed because the enum was
designed when there were five fixed templates chosen from a list, and the
intake no longer works that way.

An invalid combination — render without chat, or nothing at all — is
unrepresentable at intake by construction: Render's toggle implies chat as an
input, and Add is disabled with no outputs selected.

## 6. Quality

The picker lists `VideoInfo.qualities` with an estimated size computed from
`bitsPerSecond x duration`, matching what the WPF app offers. Estimates are
labelled as estimates.

`VideoRequest.quality` becomes meaningful rather than always empty. Empty still
means "best available" — the behaviour proven against the real CLI, which
selects source when `-q` is absent — and remains the default selection.

Clips carry their own quality list from the same `info` call.

## 7. Render options

`RenderRequest` grows from seven fields to cover appearance:

| Group | Fields |
|---|---|
| Size | width, height, framerate, fontSize, font |
| Colour | backgroundColor, alternateBackgroundColor, messageColor |
| Elements | timestamps, outline, outlineSize |
| Backgrounds | alternateBackgrounds |
| Encoding | bitrateMbps, isSharpened |

Colours are stored as hex strings because that is what the CLI takes
(`#111111`, and `#C8FF0059` with alpha); the form uses a colour well and
converts.

**`chatrender`'s boolean options are switches, not `--flag=value` options —
verified empirically, not asserted from the `--help` text.** Upstream's
parser reads mere *presence* of a boolean flag as true and ignores any value
that follows it: `--timestamp=false` and `--timestamp false` both turn
timestamps ON, identically to `--timestamp` on its own. Verified against the
bundled 1.56.5 helper on 2026-08-25 by rendering the same chat file with
`--timestamp=false` and `--timestamp=true`, extracting frames from both
outputs, and hashing them: the two renders were byte-identical (sha256
`d9b7fea7be2a10be…`), and both differed from a render that omitted the flag
entirely (`6a2b525002429b03…`). The same check on `--outline` gave the same
shape: `=false` and `=true` identical (`735d58632d7ada2c…`), omission
different (`53952cd96edf2289…`). **There is no way to pass `false` through
this CLI for these options; omitting the flag is the only way to get it.**

`--banner` is a genuine, verified exception: it is declared differently
upstream, and `--banner=false` really does suppress the banner. It is the
one flag in `ArgumentBuilder` that keeps the `=value` shape.

Given that, only the three options whose CLI default is `false` — timestamps,
outline, and alternate backgrounds — are expressible through this CLI at all:
`ArgumentBuilder` emits them bare (`--timestamp`, not `--timestamp=true`) when
the user wants them on, and omits them otherwise. The other six upstream
switches this design originally meant to expose — badges, sub-messages, and
the four emote toggles (bttv, ffz, stv, allow-unlisted-emotes) — all default
to `true` and **cannot be turned off through this CLI at all**. `RenderRequest`
carries no fields for them; a settable field that can never take effect is a
lie. They stay on, at the CLI's own default — the emote switches in
particular were meant to be surfaced deliberately (7TV resolution is why the
submodule is pinned past `1.56.5`, `docs/development.md`), but "on by
upstream default, not user-controllable" is what that surfacing amounts to
until an upstream fix changes the parsing.

Every option above is emitted by `ArgumentBuilder` and asserted in its tests,
including the empirically-derived contract itself — see the comment above
`ArgumentBuilderTests`'s boolean-flag suite. The two GPL-avoidance rules are
unchanged and non-negotiable: always `--output-args` with
`h264_videotoolbox`, never `--sharpening`.

## 8. Clips

Parity with the WPF app, which offers clips as a first-class download.

`TwitchVideoURL` currently **rejects** clip URLs deliberately; it becomes
`TwitchLink`, returning either a video id or a clip slug. Accepted forms:
`twitch.tv/<channel>/clip/<slug>`, `clips.twitch.tv/<slug>`, and a bare slug.

The CLI's `chatdownload` takes "a VOD or clip", so a clip's chat and its render
work through the same toggles. Clips have no trim options, so those are hidden
rather than disabled.

## 9. What does not change

`QueueEngine`, `Scheduler`, `Reconciler`, persistence, and the queue views need
no behavioural change. Destinations are computed at intake and set on the
requests, which each already carry their own — so multi-output jobs need no new
engine concept, and nothing about scheduling, artifact handoff, or restart
reconciliation is touched.

The exception is `JobTemplate.makeJob`, which §5 rewrites. It is the one piece
of existing engine-adjacent code this slice changes, and its callers —
`QueueController` and the template tests — change with it.

`JobRow`'s disclosure already draws multi-step jobs; this is the first slice
that will actually give it one to draw.

## 10. Testing

| Unit | Covered by |
|---|---|
| `TwitchLink` | VOD forms, clip forms, bare ids and slugs, rejections |
| `VideoInfo` parsing | real captured `info --format Raw` output as a fixture |
| Quality parsing | `EXT-X-STREAM-INF` lines, including a variant list with one entry |
| Filename derivation | illegal characters, byte-cap truncation, emoji and ZWJ sequences, suffix reservation, trailing-separator trim |
| Local date conversion | a UTC timestamp that falls on the previous local day |
| `JobTemplate` composition | every toggle combination produces the right steps and `dependsOn` |
| `ArgumentBuilder` | each new render option; the two GPL rules still hold |
| `QueueController` | metadata fetch success and failure; enqueue with multiple destinations |

`info --format Raw` output is captured as a fixture the way the CLI status
fixtures already are, so parsing is tested without the network.

## 11. Not in scope

Deliberately, from the WPF feature set: OAuth for sub-only and private VODs
(a credential, and it deserves its own design rather than a text field bolted
on); the `chatupdate` verb; mass download by URL list or streamer search;
per-type concurrency limiters; trim mode (exact versus safe); and download
thread count.

Also out: `{part}` in the filename template — Oxbow never splits a VOD, so
there is nothing for it to mean.
