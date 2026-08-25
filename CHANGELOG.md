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

Pre-alpha. Nothing released yet.

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
- One intake sheet for the whole job: paste a link, toggle video, chat, and
  render independently, and choose one destination folder for all of them.
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
  (`docs/design/compositing.md`). The engine, scheduler, geometry derivation,
  argument builder, and progress parsing all exist and are tested, but the
  feature is **not reachable from the UI yet** — no intake constructs a
  composite. That is Phase 4, tracked separately.

### Changed

- `Step.dependsOn` is `[StepID]` rather than a single optional `StepID`, since
  a composite step depends on two finished steps (its media and its render)
  rather than one. A queue persisted by an older build still loads: the
  decoder accepts either the old scalar shape or the new array and no
  migration step is needed.

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
