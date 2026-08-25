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
| quality *name* | CLI, derived | **Unusable as `-q`** when it ends `-<digits>`. |
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

## 5. Quality names with a numeric suffix do not resolve

Twitch returns duplicate identical renditions, so the CLI disambiguates them by
appending `-1`, `-2`. Those names then fail to resolve as `-q`, and the CLI
silently falls back to the **best** rendition:

| `-q` | downloaded |
|---|---|
| `480p30-1` | 1920x1080 |
| `480p30-2` | 1920x1080 |
| `720p60-1` | 1920x1080 |
| `480p30` | 852x480 |
| `720p60` | 1280x720 |

Exit 0, no warning. `-Portrait` suffixes are unaffected and resolve correctly.

**The rule: strip a trailing `-<digits>` before passing a name as `-q`.** Strip
only a hyphen followed by digits — never a bare trailing digit, or `720p0`
becomes `720p` and every clip missing framerate metadata breaks.

Keep the unstripped name for display: it is what distinguishes duplicate
renditions in a picker.

## 6. Whose bug is whose

Worth separating, because the three categories need different responses.

**Twitch's** — bad or lossy metadata: odd pixel dimensions, averaged frame
rates, non-integer frame rates, duplicate renditions, zeroed fields on old
clips. None of these break a download; they break anything that reasons about a
video before fetching it. We can only defend against them, which is what
sections 3-5 are.

**The CLI's** — see [[twitch-downloader-cli-upstream-prs]] in the maintainer's
notes for the full list. The two strongest: `--flag=false` being parsed as true
on `chatrender` booleans, and the `-q` round-trip failure above, where the CLI
generates names it cannot itself consume.

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
