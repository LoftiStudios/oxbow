#!/usr/bin/env bash
#
# Xcode Run Script phase: stamp the build number and the bundled component
# versions into the built Info.plist.
#
# MARKETING_VERSION (CFBundleShortVersionString) is a committed constant in
# Config/Shared.xcconfig — it is the semver in CHANGELOG.md and it changes by
# hand. Everything this script writes is derived, so none of it belongs in a
# file a human edits:
#
#   CFBundleVersion   the repository's commit count. CFBundleVersion has to
#                     increase monotonically across shipped builds, and a
#                     number nobody has to remember to bump is the only kind
#                     that reliably does. Squash-merges keep main linear, so
#                     the count only ever goes up.
#
#                     Deriving it here rather than on the runner is what keeps
#                     a local ⌘R build and a CI build agreeing: one mechanism,
#                     one source of truth, no divergence to debug later.
#
#   OXHelperVersion   TwitchDownloaderCLI's own `--version` output, e.g.
#                     `1.56.5+d4122d8021…`. The full commit sha is the point —
#                     it makes a shipped DMG traceable to the exact upstream
#                     commit the submodule was pinned to (docs/development.md,
#                     "Upstream"). The About window shows it.
#
#   OXFFmpegVersion   the FFMPEG_VERSION pin from scripts/build-ffmpeg.sh,
#                     read the same way .github/workflows/full-build.yml reads
#                     it. Written only when build/ffmpeg/ffmpeg actually
#                     exists, so the key's presence means "this bundle has an
#                     FFmpeg in it", not "this repo could build one".
#
# Why a build phase and not a `defaults write` after the fact: Xcode seals the
# bundle in its own CodeSign step, which runs after every build phase. Editing
# Info.plist here therefore lands before signing. Editing it afterwards would
# break the signature.
#
# THE PHASE MUST DECLARE $(TARGET_BUILD_DIR)/$(INFOPLIST_PATH) AS AN INPUT.
# Do not remove that from the pbxproj. Info.plist generation is not a build
# phase — it is an independent ProcessInfoPlistFile task — so listing this
# script last in the target's phase order guarantees nothing. Without the
# declared input the build system is free to schedule the two either way, and
# it does: a clean build happened to run the plist task first and stamp
# correctly, while every incremental build ran it second and overwrote
# CFBundleVersion back to the CURRENT_PROJECT_VERSION fallback. Reproduced
# three times in a row before and after the fix. Declaring the input makes the
# ordering an edge in the dependency graph instead of a coincidence.
#
# Unlike scripts/embed-helpers.sh this NEVER early-exits on a missing helper.
# A UI-only build with no .NET or FFmpeg toolchain (the fast path
# CONTRIBUTING.md promises) still gets a correct build number; it just reports
# the components as absent, which is exactly what the About window should say
# about it.
#
set -euo pipefail

: "${TARGET_BUILD_DIR:?must run from an Xcode Run Script phase}"
: "${INFOPLIST_PATH:?must run from an Xcode Run Script phase}"
: "${SRCROOT:?must run from an Xcode Run Script phase}"

PLIST="${TARGET_BUILD_DIR}/${INFOPLIST_PATH}"
PLISTBUDDY=/usr/libexec/PlistBuddy

warn() { echo "warning: stamp-version: $*"; }
note() { echo "note: stamp-version: $*"; }
die()  { echo "error: stamp-version: $*" >&2; exit 1; }

[[ -f "${PLIST}" ]] || die "no Info.plist at ${PLIST} — this phase must run after Xcode processes the Info.plist"

# `Set` fails on a key that does not exist and `Add` fails on one that does,
# so try Set first and Add only as the fallback. CFBundleVersion is always
# already there (GENERATE_INFOPLIST_FILE writes it from
# CURRENT_PROJECT_VERSION); the OX* keys never are.
put() {
  local key="$1" value="$2"
  "${PLISTBUDDY}" -c "Set :${key} ${value}" "${PLIST}" 2>/dev/null \
    || "${PLISTBUDDY}" -c "Add :${key} string ${value}" "${PLIST}" \
    || die "could not write ${key} to ${PLIST}"
}

# ------------------------------------------------------------- build number
if git -C "${SRCROOT}" rev-parse --git-dir >/dev/null 2>&1; then
  # A shallow checkout counts only the commits it was given — actions/checkout
  # defaults to depth 1, which would silently stamp every CI build as 1 and
  # break monotonicity for anything cut from a runner. The workflows pass
  # fetch-depth: 0 for exactly this reason; say so loudly if that regresses.
  if [[ "$(git -C "${SRCROOT}" rev-parse --is-shallow-repository 2>/dev/null)" == "true" ]]; then
    warn "shallow checkout — the commit count is not the real one. Set fetch-depth: 0 on actions/checkout."
  fi
  BUILD_NUMBER="$(git -C "${SRCROOT}" rev-list --count HEAD)"
  put CFBundleVersion "${BUILD_NUMBER}"
  note "CFBundleVersion ${BUILD_NUMBER} (commit count)"
else
  # An exported tree or a source tarball has no history to count. Leave
  # whatever CURRENT_PROJECT_VERSION put there rather than inventing a number.
  warn "not a git repository — leaving CFBundleVersion at the CURRENT_PROJECT_VERSION fallback"
fi

# ----------------------------------------------------------- helper version
HELPER="${SRCROOT}/build/helper/TwitchDownloaderCLI"
if [[ -x "${HELPER}" ]]; then
  # `--version` prints `TwitchDownloaderCLI 1.56.5+<sha40>` — but ON STDERR,
  # and it exits 1. CommandLineParser treats it as "no verb given" rather than
  # as a successful command. Verified against the real published helper; the
  # obvious `2>/dev/null` and the obvious exit-status check both silently
  # yield nothing.
  #
  # Captured whole before parsing, never piped into `head`. Under `set -o
  # pipefail` a `head -1` that exits early SIGPIPEs the producer and fails the
  # whole pipeline — the same trap .github/workflows/full-build.yml documents
  # for `grep -q`. This is how that bug looks here: an empty version and a
  # failed build.
  helper_raw="$("${HELPER}" --version 2>&1 || true)"
  # Require the expected leading field rather than blindly taking $2, so that
  # if upstream ever replaces this output with an error message we stamp
  # nothing instead of stamping the error's second word as a version.
  helper_version="$(awk 'NR == 1 && $1 == "TwitchDownloaderCLI" { print $2 }' <<<"${helper_raw}")"
  if [[ -n "${helper_version}" ]]; then
    put OXHelperVersion "${helper_version}"
    note "OXHelperVersion ${helper_version}"
  else
    warn "helper at build/helper produced no --version output; omitting OXHelperVersion"
  fi
else
  note "no helper at build/helper — omitting OXHelperVersion"
fi

# ----------------------------------------------------------- ffmpeg version
if [[ -x "${SRCROOT}/build/ffmpeg/ffmpeg" ]]; then
  ffmpeg_version="$(sed -n 's/^FFMPEG_VERSION="\(.*\)"$/\1/p' "${SRCROOT}/scripts/build-ffmpeg.sh")"
  if [[ -n "${ffmpeg_version}" ]]; then
    put OXFFmpegVersion "${ffmpeg_version}"
    note "OXFFmpegVersion ${ffmpeg_version}"
  else
    warn "could not read FFMPEG_VERSION from scripts/build-ffmpeg.sh; omitting OXFFmpegVersion"
  fi
else
  note "no FFmpeg at build/ffmpeg — omitting OXFFmpegVersion"
fi
