# Captured TwitchDownloaderCLI output

Real bytes from real runs, not hand-written. They exist because the CLI's
progress protocol is `\r`-delimited and a hand-written fixture would quietly
encode whatever the author assumed rather than what the CLI does.

Captured 2026-08-23 against `TwitchDownloaderCLI 1.56.5+d4122d8` with stdout
redirected to a file (a pipe, not a TTY - the CLI does not check).

| File | Source |
|---|---|
| `videodownload-success.stdout` | `videodownload --id 2844548319 -q 160p -b 0s -e 40s` |
| `chatdownload-success.stdout` | `chatdownload --id 2844548319 -b 0s -e 40s` |
| `chatrender-success.stdout` | `chatrender` over the above chat, `h264_videotoolbox` |
| `videodownload-invalid-vod.stderr` | `videodownload --id 999999999999` |
| `info-vod-raw.stdout` | `info --id 2844548319 --format Raw` |

Captured 2026-08-24 against the same build:

| File | Source |
|---|---|
| `info-clip-raw.stdout` | `info --id AbstemiousSillyPuppyBCouch-x_zVHj6Yc6UvUVuu --format Raw` |
| `info-clip-legacy-raw.stdout` | `info --id CaringColdbloodedShrewPraiseIt --format Raw` |

The two clip fixtures are the **only** files here that were edited after
capture: each clip's `playbackAccessToken` — a signed, expiring CDN
credential — has had its `signature` and `value` replaced with
`REDACTED-SIGNATURE` / `REDACTED-TOKEN`. Nothing else was touched, and nothing
we parse reads that field.

They are two fixtures rather than one because clip payloads differ by age.
The 2026 clip carries two assets (a landscape and a portrait re-crop) with
real bitrates, framerates and pixel dimensions; the 2020 clip carries one
asset whose `bitrate` and `frameRate` are zero. Its `width` and `height` are
present (1280x720, 852x480, 640x360), so the aspect-ratio fallback for a
missing resolution is exercised by a synthetic case in `VideoInfoTests`, not by
this fixture — what this fixture pins is that a zero bitrate produces no size
estimate rather than "about Zero KB".

The 2020 clip pins one more thing, discovered later: its `video` and
`videoOffsetSeconds` are both `null`, because Twitch expired the broadcast it
was cut from years ago. That is the exact pair upstream's
`ChatDownloader.InitChatRoot` tests before throwing "Invalid VOD for clip,
deleted/expired VOD possibly?", so this fixture is also our only captured
example of a clip whose chat cannot be downloaded — see
`VideoInfo.hasDownloadableChat`. Replacing it with a *recent* clip would keep
every assertion above passing while silently deleting that coverage. Both list every rendition twice, which is why quality names carry
upstream's `-1` disambiguator.

A clip's `Raw` output is a different document from a VOD's — one JSON object
under `data.clip`, no moments line, no m3u8 section, and **no trailing
newline** — so it only reaches a parser through `StatusLineParser.finish()`.

CR/LF counts, which are the point:

| File | `\r` | `\n` |
|---|---|---|
| videodownload-success | 9 | 4 |
| chatdownload-success | 6 | 3 |
| chatrender-success | 401 | 4 |
| videodownload-invalid-vod.stderr | 0 | 14 |

`chatrender-success.stdout` is the important one: **401 progress updates
arriving inside 4 newline-delimited lines**. A parser that splits on `\n`
sees four lines and reports 100% only at the very end.

Do not regenerate these casually - they are a record of upstream behaviour at a
known commit. If upstream changes its output format, add new fixtures rather
than overwriting these, so the parser can be tested against both.
