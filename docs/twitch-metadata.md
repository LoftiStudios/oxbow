# What Twitch's metadata says, and how far to trust it

**Status:** written 2026-08-25, from findings while building compositing.

Every claim here was measured against the real API and the real decoded bytes on
2026-08-25. Nothing is inferred from documentation, because there isn't any.

---

## 1. Why this document exists

Until compositing, Oxbow never had to *reason* about a video before downloading
it. Metadata picked a filename and populated a quality menu; if a field was
slightly wrong, nothing broke.

Compositing changed that. The chat column's height must equal the video's, and
its width sets the output resolution — so the app now commits to geometry
**before a byte arrives**, based entirely on metadata. That made accuracy
load-bearing for the first time, and immediately surfaced several fields that
are wrong, approximate, or unusable.

The rule that follows from all of it: **metadata is a planning hint, not a
description of the file.** Anything that must be exact has to be derived
defensively or verified after decode.

## 2. The trust table

| Field | Source | Trust | What's actually true |
|---|---|---|---|
| `width` / `height` (clip API) | Twitch | **Low** | Can be odd. Round DOWN to even. |
| `RESOLUTION` (VOD m3u8) | Twitch | Medium | Even, but disagrees with the clip API for the same rendition. |
| `FRAME-RATE` (VOD m3u8) | Twitch | **Do not use** | A measured average, not the container rate. |
| `frameRate` (clip API) | Twitch | Low | Non-integer; `0` on older clips. |
| quality *name* | CLI, derived | High for framerate | `1080p60` -> 60. The only reliable framerate source. |
| quality *name* | CLI, derived | **Valid only against the response it came from** | Renditions change between calls; a `-<digits>` suffix resolves fine while it exists. |
| `lengthSeconds` | Twitch | High | Matches the decoded duration. |

## 3. Pixel dimensions can be odd, and the stream cannot

Twitch's clip API reported this rendition:

```
{'quality': '480', 'frameRate': 30.0155..., 'width': 480, 'height': 853}
```

The file it actually serves decodes as:

```
Video: h264 (Main), yuvj420p, 480x852
```

**An h264 4:2:0 stream cannot have an odd dimension** — chroma is subsampled by
two in both axes. So 853 is simply wrong, and it comes from Twitch: it is
present verbatim in the raw payload, not derived by the CLI or by us.

The same nominal 480p rendition reads `852x480` from a VOD's m3u8 and `853x480`
from the clip API, so the two sources do not even agree with each other.

**Why it mattered.** We sized the chat column from `height`. At 853 against a
real 852, `hstack` refuses to stack mismatched heights and the job dies at frame
0 — a loud failure, but for a rendition that would otherwise work fine.

**The rule: round both dimensions down to even before using them.** Cheap,
matches every observed case, and if it is ever wrong the failure stays loud
rather than becoming a silently wrong frame.

Related, and worse if missed: `h264_videotoolbox` does **not reject** an odd
output dimension. It accepts it and silently crops (1920+351 produced 2270x1080,
exit 0, no warning at `-loglevel error`). So an odd dimension that survives into
the encoder does not fail — it quietly changes the output.

## 4. `FRAME-RATE` is a measured average

A VOD's m3u8 advertises `FRAME-RATE=57.034` for a stream whose container
reports:

```
1920x1080, 57.03 fps, 60 tbr
```

57.03 is the average frames actually delivered; 60 is the rate the file is in.
Using the former to drive `fps=` in a filter graph introduces exactly the drift
that normalising the chat rate exists to prevent.

**The rule: derive framerate from the quality NAME** (`1080p60` -> 60), never
from `FRAME-RATE`.

The clip API is no better — it reports `60.03107452392578` and
`30.01553726196289` — and returns `0` for older clips, which is why names like
`720p0` and `1080p0-Portrait` exist. A name yielding 0 must fall back to 30.

## 5. A clip's rendition list is not stable between calls

**Corrected 2026-08-25.** This section previously claimed the CLI generates
`-1`/`-2` names it cannot itself consume, and prescribed stripping the suffix.
That diagnosis was wrong. The measurements were real; the conclusion drawn from
them was not, because they were taken 29 minutes apart against a payload that
changed in between.

What was actually measured, all on clip
`BitterPoorLadiesNerfRedBlaster-MBUzt9WrmWvpraw3`:

| When | What | Result |
|---|---|---|
| 23:12 | `info --format Table` | `1080p60-1/-2`, `720p60-1/-2`, `480p30-1/-2` — six rows, three duplicated pairs |
| 23:28 | `clipdownload -q 480p30-1` | decoded `1920x1080 [...] 6128 kb/s` — the 1080p60 rendition |
| 23:41 | `info --format Raw` | eight renditions, **no duplicates**: 1080/720/480/360 landscape + 1296/720/480/360 portrait |

So by the time the download ran, `480p30-1` was not a name the CLI was
generating any more. Twitch had stopped returning the duplicated landscape
asset and started returning a landscape/portrait pair instead. The name was
captured from one response and spent against a different one.

Verified against the CLI's own source: `VideoQualities.TryGetQuality` matches
the full name first, so a `-1`/`-2` name that currently exists **does** resolve.
A unit test on that code confirms it — the round trip is not broken.

**The rule: a rendition name is only valid against the response it came from.**
Re-fetch and re-match rather than caching a name across calls, and treat a
`-q` that no longer exists as a real possibility. Do not strip the suffix — when
the duplicates are genuine, stripping silently swaps the user's `-1` pick for
whichever of the pair sorts first.

Two things make this invisible rather than loud, and both are worth knowing:

- The CLI falls back to the **best** rendition for any unresolvable `-q`, exit
  0, no warning. Documented behaviour (`-q` is "the quality the program will
  *attempt* to download"), but it is why a stale name reads as a parser bug.
- The CLI disambiguates duplicate names **per asset**, then concatenates across
  assets. Two same-orientation assets therefore produce identical names with no
  suffix at all, and the second of each pair is unreachable via `-q`. Not
  observed in the wild, but it is the shape this failure would really take.

## 6. Whose bug is whose

Worth separating, because the three categories need different responses.

**Twitch's** — bad or lossy metadata: odd pixel dimensions, averaged frame
rates, non-integer frame rates, duplicate renditions, zeroed fields on old
clips. None of these break a download; they break anything that reasons about a
video before fetching it. We can only defend against them, which is what
sections 3-5 are.

**The CLI's** — see [[twitch-downloader-cli-upstream-prs]] in the maintainer's
notes for the full list. The strongest by far: `--flag=false` being parsed as
true on `chatrender` booleans. The `-q` round-trip failure that used to be
listed here was ours, not the CLI's — see §5.

**Ours** — trusting any of the above without defending. Every rule in this
document exists because we did, once.

## 7. The verification lesson

Every one of these survived a green test suite.

`ArgumentBuilder`'s tests assert the argv **string**; they passed the entire
time `--timestamp=false` was turning timestamps on. `CompositeGeometry`'s tests
assert **integers**; they passed while those integers described a frame the
encoder would silently crop. The composite bitrate had tests too, and the
artifacts were only ever visible in decoded pixels.

**A test that asserts what we send cannot catch what the tool does with it.**
Anything at the boundary — argv, geometry, encoder behaviour — needs at least
one check against the real binary and the real decoded output, once, recorded
here with its evidence.
