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
- Chat text size: a Small / Medium / Large picker for the video + chat intake,
  scaling with the video's own resolution (`CompositeGeometry.fontSize(for:)`)
  rather than a fixed point size, so the same column reads correctly at 480p
  and 1080p alike.

### Changed

- The bundled TwitchDownloaderCLI helper is now published trimmed
  (`-p:PublishTrimmed=true -p:TrimMode=partial`), taking it from **126 MB /
  204 files to 67 MB / 85 files** and the app bundle from ~147 MB to ~94 MB.
  ILLink removes unreachable managed code only: the 17 native Mach-Os, the
  entitlement set (`allow-jit`, still no `disable-library-validation`), and the
  sign-every-file model are all unchanged. `PublishSingleFile` remains
  forbidden permanently — it is a separate flag and trimming does not soften
  that. Adopted only after every verb (`info`, `chatdownload`, `chatrender`,
  `videodownload`, `clipdownload`) was compared against an untrimmed build on
  decoded output rather than exit status.

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
