# Changelog

All notable changes to Oxbow are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

Entries record changes to **Oxbow**. Bumps to the pinned
`vendor/TwitchDownloader` submodule are noted under Changed, with the upstream
version they move to, because they change what the shipped helper does.

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

### Changed

- `JobTemplate` is a composition of three optional parts (media, chat, render)
  rather than an enum of five fixed combinations. Every previous case is still
  expressible, and combinations the enum could not express — video plus chat
  without a render, and the clip equivalents — now are.
