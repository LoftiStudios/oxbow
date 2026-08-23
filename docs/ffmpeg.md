# FFmpeg: sourcing, licensing, and the arguments Oxbow must override

**Status:** resolved. Spike run 2026-08-23; `scripts/build-ffmpeg.sh` is the outcome.

`docs/handoff.md` §5 asserted "bundle our own LGPL build" as a decision but not as a
plan. This document is the plan, plus the things the spike turned up that the
handoff did not anticipate.

---

## 1. Why we build it ourselves

Every readily-available macOS FFmpeg binary is GPL, because they all enable
libx264. Verified, not assumed:

| Source | Evidence | Verdict |
|---|---|---|
| Homebrew `ffmpeg` 8.1.1 | `--enable-gpl --enable-libx264 --enable-libx265` in its own `-version` output | GPL. Unusable. |
| evermeet.cx 9.0.1 | Its build manifest lists `x264`, `x265`, `rubberband`, `vid.stab`, `xvidcore` (GPL-only) and `faac` (nonfree) | GPL + nonfree. Unusable. |

The key fact that makes building ourselves easy: **FFmpeg's `configure` defaults to
LGPL 2.1+.** GPL is opt-in via `--enable-gpl`. We simply never pass it, and
`configure` prints `License: LGPL version 2.1 or later` as confirmation. The build
script fails hard if that line ever changes.

`--disable-autodetect` is what makes the build reproducible. Without it, `configure`
links against whatever Homebrew has installed, which breaks self-containment and can
silently change the license surface.

## 2. What the spike produced

Two variants, both LGPL 2.1+, both arm64, both verified against the real pipelines:

| | Full (default) | Minimal (`MINIMAL=1`) |
|---|---|---|
| Size | 20 MB | 5.9 MB |
| Dynamic deps | System frameworks + `libSystem` only | same |
| VOD concat/remux | pass | pass |
| Chat render (raw frames → h264_videotoolbox) | pass | pass |
| Output bytes | identical | identical |

**Ship the full build.** The 14 MB saving is noise next to a self-contained .NET
helper, and the minimal build's component list is a standing liability: it breaks the
moment a user supplies custom FFmpeg arguments or Twitch changes a container. The
minimal path stays in the script because it costs one `if` block and it is the right
answer if bundle size ever becomes a real constraint.

Both builds depend on nothing but macOS system frameworks, so FFmpeg contributes
exactly **one Mach-O to sign** — the best possible case for the signing spike.

`--disable-network` is deliberate. Oxbow only ever hands FFmpeg local files and
pipes, so the binary has no `http`/`https` protocol support at all. It cannot reach
the network even if something tried to make it.

## 3. The libx264 trap — read this before writing the render UI

`TwitchDownloaderCLI`'s **default** chat-render output arguments are:

```
-c:v libx264 -preset veryfast -crf 18 -pix_fmt yuv420p "{save_path}"
```

That is a GPL encoder. Against our LGPL binary it fails outright. Oxbow must
**always** pass `--output-args` explicitly. This is not a tuning preference; the
default is broken for us by construction.

Working replacement, verified end-to-end at 6.7× realtime:

```
-c:v h264_videotoolbox -b:v {bitrate} -pix_fmt yuv420p "{save_path}"
```

Note `h264_videotoolbox` is quality-targeted by bitrate, not CRF — there is no
`-crf` equivalent. The render settings UI needs a bitrate control, not a quality
slider mapped to CRF.

### `--sharpening` cannot be passed through

`RenderChat.cs` implements `--sharpening` by appending
`-filter_complex "smartblur=lr=1:ls=-1.0"`. FFmpeg's `configure` declares
`smartblur_filter_deps="gpl swscale"` — **smartblur is GPL-only** and is absent from
our binary.

`unsharp` was relicensed to LGPL and is present. Oxbow's sharpening toggle must build
its own `unsharp` filter string rather than forwarding `--sharpening` to the CLI.

## 4. Required component surface

Derived by reading every FFmpeg invocation in `vendor/TwitchDownloader`, not guessed:

| Path | Source | Arguments |
|---|---|---|
| VOD finalize | `VideoDownloader.RunFfmpegVideoCopy` | `-avoid_negative_ts make_zero -analyzeduration MAX -probesize MAX -f concat -max_streams MAX -i concat.txt -i meta.txt -map_metadata 1 -c copy out` |
| Clip finalize | `ClipDownloader` | `-i in -i meta -map_metadata 1 -y -c copy out` |
| Chat render in | `ChatRenderArgs` default | `-framerate {fps} -f rawvideo -analyzeduration MAX -probesize MAX -pix_fmt {bgra\|rgba} -video_size {w}x{h} -i -` |
| Chat mask in | `ChatRenderer.GetFfmpegProcess` | same, with `-pix_fmt gray` |

This implies: `concat` / `rawvideo` / `mpegts` / `mov` / `ffmetadata` demuxers,
`mp4` + `mov` muxers, `rawvideo` decoder, `h264_videotoolbox` encoder, `file` +
`pipe` protocols, and the `aac_adtstoasc` bitstream filter — the last is what makes
AAC stream-copy from `.ts` into `.mp4` work, and is easy to miss.

Two details worth recording:

- VOD parts are `.ts` (mpegts) and the concat list is `ffconcat version 1.0` with
  `exact_stream_id` entries. Metadata is `;FFMETADATA1`.
- The mask render feeds `gray` frames. `h264_videotoolbox` accepts them and converts
  to `yuv420p` on its own — no explicit `-pix_fmt` needed, though passing it is
  harmless. `qtrle` is *not* a usable mask codec: it rejects widths that aren't a
  multiple of 4, and the default chat width is 350.

## 5. The runtime downloader never fires

`FfmpegHandler.DownloadFfmpeg` only runs when the user explicitly invokes the
`ffmpeg -d` subcommand. `DetectFfmpeg` merely errors out when no binary is found. So
passing `--ffmpeg-path` to our bundled binary and never exposing the `ffmpeg` verb in
the GUI is sufficient — there is no ambient code path that would fetch an unsigned
binary behind our backs.

## 6. LGPL compliance

We distribute `ffmpeg` as a standalone executable of unmodified FFmpeg code. We do
not link it into Oxbow, so the LGPL §6 relinking obligation is satisfied trivially.
Requirements, all emitted into `build/ffmpeg/` by the build script:

- `COPYING.LGPLv2.1` — the license text.
- `FFMPEG-SOURCE.txt` — version, upstream URL, source SHA-256, and the exact
  `configure` line, so anyone can reproduce the binary.

Both must be included in the DMG and referenced from the About box.

## 7. Open items this spike did not close

- **`MIN_MACOS` is a placeholder.** The script pins `13.0`; the app's deployment
  target is still unset (`docs/handoff.md` §10). These two values must match — a
  helper built for a newer minimum than the app fails to launch on the app's oldest
  supported OS. Set both together when the deployment target is decided.
- **FFmpeg 9.0.1 exists.** We pinned 8.1.2 as the conservative choice. Revisit
  before 1.0.
