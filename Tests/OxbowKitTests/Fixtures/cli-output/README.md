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
