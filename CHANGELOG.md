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

### Fixed

- **The Mac no longer idles to sleep while the queue is working.** A download
  or an encode is a child process, and a child process is not something the
  idle timer counts — so an eighty-eight minute composite on a Mac nobody was
  touching lost to Energy Saver about forty minutes in, and was still sitting
  there, suspended, whenever its owner came back. Oxbow now holds a
  `.userInitiated` activity assertion for exactly as long as it has a step in
  flight, and gives it back the moment the queue settles, fails, is cancelled,
  or the app quits. Deliberately not a display assertion: a long encode is no
  reason to keep a screen lit all night. This cannot help a laptop whose lid is
  closed with no external display — macOS forces that sleep below the level any
  application can reach.

## [0.3.0] - 2026-08-31

**This release requires macOS 26.** No hardware is dropped — Oxbow has always
been Apple Silicon only, and every Mac that can run it can run macOS 26 — but
someone still on macOS 15 has to update the OS before updating Oxbow. 0.2.1
remains the last release that runs there. The bundled FFmpeg was rebuilt with a
matching `MIN_MACOS`, which `scripts/build-ffmpeg.sh` requires be kept in
lockstep with the app's deployment target.

Two changes account for most of what a user will notice. The intake is rebuilt
around a trim timeline you drag rather than two text fields, and the composite
asks its encoder for a quality instead of computing a bitrate — which is why a
quiet stream now produces a file roughly a fifth the size it used to, at the
same quality, while a busy one finally gets the bits it was being starved of.

### Added

- **A trim timeline.** Choosing part of a VOD is now a draggable range on a
  ruler, with Start, End and the resulting duration on one row beneath it.
  Handles snap to a unit derived from the video's length, the ruler labels its
  exact endpoints, and both ends are adjustable from VoiceOver. The handles are
  deliberately not in the tab chain: a slider is one tab stop on this platform,
  never two, and the Start and End fields already carry the same two values in
  reading order.
- **An update check.** A banner in the queue window when a newer release
  exists, and a "Check for Updates" menu item that is never silent — the
  automatic check says nothing unless there is an update, so the menu item is
  the only way to tell "up to date" from "broken". Throttled to once a day, and
  a dismissal means "not this one" rather than "never again". It reads
  `/releases/latest`, which excludes drafts, so a release stays invisible until
  a human publishes it.
- **A warning before replacing an existing file.** Finishing a download used to
  overwrite whatever sat at the destination with no warning and no record. The
  intake now checks the destination as the name and folder change, says so
  under the name field, and relabels Add to Replace. Nothing is blocked —
  re-downloading over a bad copy should stay one click — but the click is named
  for what it does. A job that carries no such permission steps to the next free
  name (`out (2).mp4`) instead of clobbering, and Get Info and Show in Finder
  name the file that actually exists.
- **The composite's projected output size**, shown while it encodes. Constant
  quality means the size cannot be known in advance, so it is projected from
  FFmpeg's own `total_size` — withheld below 2% complete, where the opening
  I-frames over a tiny denominator produce a number that visibly collapses
  rather than converges. It is the only warning a runaway encode gives while
  there is still time to cancel it.
- The status icon in Get Info, so the window and the queue row it was opened
  from cannot disagree about what a status looks like. The word stays: the icon
  is the glanceable half and the word the exact one.
- `scripts/bench-composite.sh`, which measures a machine's composite encode
  ceiling in output megapixels per second. `docs/composite-performance.md` §5
  predicts any job's wall clock from that one constant, and it was measured on
  one machine; this makes re-deriving it runnable rather than a page of
  commands needing a checkout and a built FFmpeg.

### Changed

- **The composite asks for a quality, not a bitrate.** `-q:v 50` replaces a
  computed `-b:v`. Measured across sixteen VOD and clip samples, one quality
  setting holds the chat column within 1.9 dB while the bitrate it chooses
  spans 5.3x, and beats a fixed target by +6.3 dB at the *same* bitrate —
  because a fixed target spreads bits evenly through time and the chat column's
  difficulty is not. Over six hours that is about 9 GB instead of 48 for a 2D
  RPG, and 41 instead of 48 for the busiest content measured.

  The bitrate this replaces was not merely imprecise, it was pointed the wrong
  way: it took the source's advertised `BANDWIDTH` as its primary term, and
  across four VODs that term is anti-correlated with need — the two whose chat
  columns were visibly starved advertised the *lower* bandwidth. `-maxrate` is
  deliberately absent; it reads as the obvious guard against a runaway and does
  the opposite, taking ordinary content from 5.0 to 19.3 Mbps because it
  switches the encoder out of quality mode rather than bounding it. See
  `docs/design/composite-rate-control.md`.
- **Chat is included by default.** "Video + chat" is now the first and default
  choice at intake. Chat is the reason to reach for Oxbow over the video-only
  downloaders that already exist, and the cost of the wrong default is
  asymmetric: a user who wanted only the video clicks one radio button, while a
  user who did not know the composite existed never discovers it. The composite
  is also the only output that cannot be added after the fact.
- **The intake is ordered by the decision being made** — what this is, where to
  put it, how much of it, then how to render it. Save to moves out of the
  pinned footer and into the form, and the window now unfolds downward when a
  section opens, so the section you just asked for does not arrive below the
  fold. It never shrinks: a window the user has sized up is theirs.
- The queue list gets the system's alternating row backgrounds. Rows are not
  uniform heights — a collapsed job is one line and an expanded composite is
  five — so with several downloads listed nothing said where one job ended and
  the next began.
- Progress bars and the running status icon move off the system accent onto two
  brand values, `#62658E` in light and `#7A7DA3` in dark. A progress bar is the
  longest-lived colour on screen; a six-hour VOD means six hours of it.
- Queued steps get their own tone instead of the orange one that also means
  "something is wrong". An expanded composite put three or four orange clocks
  on screen at once, so the steps still to come read as a list of problems.
  Three states mean "not running" and they are not equivalent — a queued step
  is going to run, a blocked or cancelled one never will — so they now take two
  distinguishable greys rather than one.

### Fixed

- **A trimmed download came out with its audio about a second late.** The
  download was not at fault: a stream copy can only start video on a keyframe,
  so a trimmed VOD honestly records a leading video offset that every player
  honours. The composite threw it away — `setpts=PTS-STARTPTS` zeroed the
  video's start timestamp while the audio, remuxed untouched, kept its own, so
  the two halves of one source were rebased by different amounts. Padding the
  head instead of shifting the track takes a measured 24-frame lag to zero. The
  bug was always present at two frames; it took a trim landing off a part
  boundary to grow it to a keyframe interval and make it audible.
- **A resumed composite could deliver a file truncated at the seam.** A resume
  seeks both inputs to the same instant, which is right for the video and wrong
  for the chat render — renders end at the last message, so a stream that goes
  quiet before it ends produces a short one, and seeking past its end yields
  zero frames while FFmpeg still exits 0. The chat's seek is now clamped inside
  the render's own end, measured in the *render's* frame rate rather than the
  composite's, since the two are routinely different. Separately, a composite
  piece is now checked for declared samples and a frameless one fails the step:
  a graph that yields nothing still writes a header, so every existence check
  agreed and the empty segment was concatenated in.
- **Add Download showed the first link again on every subsequent opening.** The
  clipboard was not being misread, it was not being read: the window is one
  scene for the app's whole run, so its model outlived the window and nothing
  ever reset it. The leftover link short-circuited the guard that exists to stop
  a re-focus overwriting something half-typed. Where files go, and the chat text
  size, deliberately survive the reset — those describe how the user works, not
  this video.
- **A clip whose parent broadcast is gone is now refused at intake**, with a
  sentence saying why and pointing at video-only, which still works. A clip
  carries no chat of its own; it is reconstructed from the broadcast it was cut
  from. Waiting for that to fail mid-job was expensive in a non-obvious way: the
  chat step claims the network slot first and fails in seconds, the video
  downloads in full anyway into a workspace with no destination, and everything
  else sits blocked behind the failure — so the user waited out an entire
  download and received nothing.
- A trim left over from a previous video is cleared when a new link is pasted.
  It failed its bounds check against the new duration and left the window stuck
  with a dimmed timeline and a disabled Add button.
- The launch-time update check no longer runs during `xcodebuild test`. Tests
  run inside the app, so every test invocation made a live request to
  api.github.com and wrote to the real preferences domain. Nothing failed, which
  is why it survived a green CI run — the automatic path is silent about its own
  errors by design, so an unwanted request that succeeds and one that 403s look
  identical from outside.

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
