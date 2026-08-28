# Changelog

All notable changes to Oxbow are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

Entries record changes to **Oxbow**. Bumps to the pinned
`vendor/TwitchDownloader` submodule are noted under Changed, with the upstream
version they move to, because they change what the shipped helper does.

The version here is `MARKETING_VERSION` in `Config/Shared.xcconfig`; bump it
there as part of the release commit. The build number is not tracked here — it
is the repository's commit count, stamped into the bundle at build time by
`scripts/stamp-version.sh`.

## [Unreleased]

## [0.2.1] - 2026-08-28

Ships work that was finished before 0.2.0 went out but did not reach it. The
release workflow builds from the pushed tag, and `v0.2.0` points at the release
commit itself, so a fix merged to `main` afterwards is not in the DMG no matter
how long it sat there before publication. The trim-duration fix below was in
that position.

Nothing here changes behaviour that 0.2.0 users have already come to rely on,
so the upgrade is unconditional.

### Added

- FFmpeg's own `speed=Nx` is kept on `StepProgress` and shown next to a running
  step's remaining time. A composite that reports `0.4x` is slow; one that
  reports nothing has stalled. The bar alone could not tell those apart.
- A throttled heartbeat line — phase, fraction, speed, ETA — written into a
  running step's log every 15s. Status lines are still not logged individually;
  hundreds of them would bury the narrative lines that say what a step was
  doing when it stopped. Nothing is written if a step finishes inside the first
  interval, so short steps read exactly as before.
- A second release asset, `Oxbow-arm64.dmg`, carrying no version in its name,
  so `/releases/latest/download/Oxbow-arm64.dmg` resolves to the current build
  and a download link can be published before the version it will serve exists.
  The versioned asset is unchanged and still the one to cite when a specific
  build matters. Notarization survives the copy — the ticket is stapled into
  the DMG, not bound to its filename — and the workflow revalidates the copy so
  a regression fails the release rather than shipping an unstapled download.

  **This asset exists from 0.2.1 onward.** The 0.2.0 release predates it, so
  the `latest/download` link 404s until 0.2.1 is published.

### Fixed

- The composite's progress bar and the Add sheet's per-quality size estimate
  both measured against `info.duration`, the whole VOD's length, even when
  `trimStart`/`trimEnd` had narrowed the job to a fraction of it. The video and
  chat download requests already received the trim window; the composite's own
  `duration` did not, and `FFmpegProgressParser` divides elapsed time by it to
  derive every fraction and ETA. A 30-minute trim out of a 3-hour VOD therefore
  pinned the bar at 15–20% for the entire ~5-minute encode, which reads as a
  job that has hung for the better part of an hour. Both paths now go through
  `IntakeModel.effectiveDuration`, so the trim math exists in one place.

## [0.2.0] - 2026-08-28

First release. The app downloads a Twitch VOD or clip, optionally renders its
chat and composites the two into one file, and ships as a signed, notarized
DMG.

### Added

- Queue engine, CLI argument builder, status-line parser, and persistence layer
  (`OxbowKit`).
- Verified build, signing, and notarization pipeline (`scripts/`).
- LGPL 2.1+ arm64 FFmpeg build script (`scripts/build-ffmpeg.sh`).
- Chat download, in JSON, text, or HTML.
- Chat render, always through `h264_videotoolbox` because the CLI's default
  `libx264` is GPL and absent from our FFmpeg. `--sharpening` is never
  forwarded — it appends the GPL-only `smartblur` filter — so the Sharpen
  switch builds an `unsharp` filter string instead.
- Clips as a first-class download, from `twitch.tv/<channel>/clip/<slug>`,
  `clips.twitch.tv/<slug>`, or a bare slug.
- Filenames derived from the video's own metadata:
  `{streamer} - {date} - {title}`, with the local date, editable before the
  job is added.
- A quality picker with estimated sizes, for VODs and clips alike.
- One intake sheet for the whole job: paste a link, choose the video or the
  video with its chat composited beside it, and pick a destination folder.
  (An earlier draft of this sheet toggled video, chat, and render
  independently; narrowed to these two choices once compositing made a
  standalone chat render pointless, and the render options form that used to
  configure it — colours, font, badges, emotes, bitrate — went with it. Chat
  text size is the one control that survived, see below.)
- An About window, replacing the stock About panel, which has no room for what
  we are obliged to show: the "not affiliated with Twitch Interactive, Inc."
  disclaimer, attribution for TwitchDownloaderCLI (MIT) and FFmpeg (LGPL
  2.1+), the helper's `1.56.5+<sha>` string, and the bundled FFmpeg licence
  text and source record. The licence files are shown in place rather than
  handed to `NSWorkspace`, which has no application registered for a file
  named `COPYING.LGPLv2.1`.
- Real versioning. `MARKETING_VERSION` is `0.1.0`, and `CFBundleVersion` is
  the repository's commit count, stamped into the built `Info.plist` by
  `scripts/stamp-version.sh` so a local build and a CI build agree.
- Compositing: a `.composite` step that stacks a finished video beside its
  finished chat render into one file, via `hstack` on the bundled FFmpeg
  (`docs/design/compositing.md`), reachable from intake as the "video + chat"
  choice above.
- The composite is written as a fragmented MP4
  (`-movflags +frag_keyframe+empty_moov+default_base_moof`), so the file is
  readable while FFmpeg is still writing it — to within ~0.4s of the live edge,
  at a measured cost of 0.3s of wall clock and 123 bytes. The finished file
  stays fragmented and is fully seekable; FFmpeg writes an `mfra` index on
  close. Verified against Apple players; non-Apple players and upload pipelines
  are not verified. See `docs/design/fragmented-output.md`.
- Retrying an interrupted composite **continues** it rather than restarting,
  across app launches. A six-hour composite killed at 90% recovers in about 23
  minutes instead of re-running the whole ~88-minute job. Only possible because
  of the fragmented output above: a conventional MP4 writes its index last, so
  the same interruption leaves 26 GB of undecodable bytes and nothing to resume
  from. Resume state lives on disk rather than in the queue, so `Reconciler` and
  `Scheduler` are unchanged. See `docs/design/resume.md`.
- Chat text size: a Small / Medium / Large picker for the video + chat intake,
  scaling with the video's own resolution (`CompositeGeometry.fontSize(for:)`)
  rather than a fixed point size, so the same column reads correctly at 480p
  and 1080p alike.

### Changed

- `Step.dependsOn` is `[StepID]` rather than a single optional `StepID`, since
  a composite step depends on two finished steps (its media and its render)
  rather than one. A queue persisted by an older build still loads: the
  decoder accepts either the old scalar shape or the new array and no
  migration step is needed.

- `vendor/TwitchDownloader` points at a mirror of upstream,
  `barclay/TwitchDownloader`, rather than at `lay295/TwitchDownloader`. The
  mirror adds no code — it holds upstream's history and all 112 of its tags,
  plus `oxbow-pin-*` anchor tags that keep a pinned commit fetchable if upstream
  ever rebases or force-pushes. The pinned commit itself is unchanged.

  This unblocks shipping. The release gate required the pin to be an upstream
  *release tag*, but the pin is deliberately twelve commits past `1.56.5` for
  the 7TV emote-set endpoint migration, and upstream releases every 3-5 months.
  The gate's real concern was that a bare mid-stream SHA can be garbage
  collected; an anchor tag settles that without waiting for a release, and
  without regressing to `1.56.5`, which breaks 7TV emote resolution. The gate
  now accepts either kind of tag and says in the log which applied.
- Version settings moved out of the Xcode project, where the template had
  written `MARKETING_VERSION = 1.0` into all six target configurations, and
  into `Config/Shared.xcconfig` as a single inherited source of truth.
- `scripts/embed-helpers.sh` also stages `COPYING.LGPLv2.1` and
  `FFMPEG-SOURCE.txt` into `Contents/Resources`, so the LGPL text survives the
  app being dragged out of the DMG.
- `JobTemplate` is a composition of four optional parts (media, chat, render,
  composite) rather than an enum of five fixed combinations. Every previous
  case is still expressible, and combinations the enum could not express —
  video plus chat without a render, and the clip equivalents — now are.
  `composite` is not independent of the other three: asking for one implies a
  render exactly as a render implies a chat download.

### Fixed

Behaviour that shipped wrong on this branch before anything was released, not
regressions in a prior version:

- Render options that default to on — timestamps and the message outline —
  kept rendering even when the intake had them switched off. The CLI reads
  these flags as bare switches: mere presence means true, and it ignores
  `=false` entirely. `ArgumentBuilder` now omits a false-defaulting flag
  instead of passing `--flag=false`.
- Clip quality names with a trailing disambiguation suffix (`480p30-1`,
  `720p60-1`) silently failed to resolve against the CLI's `-q` and fell back
  to downloading the highest available rendition instead, with no error
  reported.
- The composite's bitrate was seeded from the source's own rate, which
  under-budgets the wider composite frame (video plus chat column) and
  produces visible artifacts — most noticeably mosquito noise on the chat
  text — on visually noisy sources. Corrected for the extra pixels and for
  re-encoding already-lossy material, and capped to a ceiling derived from the
  frame's own pixel rate, since a VOD's advertised bitrate is a peak rather
  than an average and would otherwise inflate a six-hour composite's file
  size unboundedly.
- Metadata dimensions Twitch reports are sometimes odd (a clip's API metadata
  can claim `480x853`), which no h264 4:2:0 stream can actually be — the real
  decoded frame is `480x852`. Every metadata dimension is now rounded down to
  even before anything derives from it, which is what a real chat/video
  height mismatch traced back to.
