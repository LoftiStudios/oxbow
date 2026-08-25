#!/usr/bin/env bash
#
# Xcode Run Script phase: embed the TwitchDownloaderCLI helper tree and FFmpeg
# into Contents/MacOS, then sign them inside-out.
#
# This is the Xcode-integration half of the signing spike (docs/signing.md §8).
# Deliberate choices, in the order they will confuse you:
#
#   - No Copy Files phase. Copy Files is where the "Code Sign On Copy" trap
#     lives: Xcode's automatic signing re-signs embedded executables during the
#     copy and clobbers their entitlements. Embedding by script sidesteps the
#     trap entirely and lets one phase guarantee sign-happens-after-embed.
#
#   - This script signs ONLY what it embeds (helper/ and ffmpeg). The app's own
#     executable and debug dylibs belong to Xcode's signing step, which runs
#     after all build phases and seals the bundle - so the inside-out order
#     (nested files first, bundle last) holds without any phase-ordering tricks.
#
#   - Missing build/helper or build/ffmpeg is a warning, not an error. UI work
#     must not require the .NET and FFmpeg toolchains (CONTRIBUTING.md promises
#     this). The build succeeds without embedded helpers; downloads just won't
#     work in that build.
#
#   - Dev builds sign with --timestamp=none: a secure timestamp is a network
#     round trip per file, and there are ~210 files. Release/distribution
#     signing always goes through scripts/sign.sh, which timestamps everything.
#
# Requires ENABLE_USER_SCRIPT_SANDBOXING=NO on the app target - this phase
# writes into the build products directory, which the script sandbox forbids.
#
set -euo pipefail

: "${TARGET_BUILD_DIR:?must run from an Xcode Run Script phase}"
: "${EXECUTABLE_FOLDER_PATH:?must run from an Xcode Run Script phase}"
: "${SRCROOT:?must run from an Xcode Run Script phase}"

HELPER_SRC="${SRCROOT}/build/helper"
FFMPEG_SRC="${SRCROOT}/build/ffmpeg/ffmpeg"
HELPER_ENTITLEMENTS="${SRCROOT}/scripts/entitlements/helper.entitlements"
DEST="${TARGET_BUILD_DIR}/${EXECUTABLE_FOLDER_PATH}"   # Oxbow.app/Contents/MacOS

warn() { echo "warning: embed-helpers: $*"; }
note() { echo "note: embed-helpers: $*"; }
die()  { echo "error: embed-helpers: $*" >&2; exit 1; }

# ----------------------------------------------------------------- have inputs?
missing=0
if [[ ! -x "${HELPER_SRC}/TwitchDownloaderCLI" ]]; then
  warn "no helper at build/helper - run the dotnet publish command in docs/development.md"
  missing=1
fi
if [[ ! -x "${FFMPEG_SRC}" ]]; then
  warn "no FFmpeg at build/ffmpeg/ffmpeg - run ./scripts/build-ffmpeg.sh"
  missing=1
fi
if (( missing )); then
  warn "building WITHOUT embedded helpers; downloads will not work in this build"
  exit 0
fi
[[ -f "${HELPER_ENTITLEMENTS}" ]] || die "missing ${HELPER_ENTITLEMENTS}"

# ----------------------------------------------------- LGPL compliance files
# The LGPL 2.1+ obligation for the FFmpeg we ship is discharged by carrying its
# licence text and a record of the exact source and configure line
# (docs/ffmpeg.md §6). Both are emitted into build/ffmpeg by
# scripts/build-ffmpeg.sh; both go in the DMG, and both go INSIDE the bundle
# so the About window's buttons still have something to open after the user
# drags Oxbow.app out of the DMG and throws the DMG away — which is what
# everyone does.
#
# Contents/Resources, not Contents/MacOS. The no-code-in-Resources rule
# (docs/signing.md §2) is about executable code; plain text is a resource, and
# putting it here keeps it out of the bundle's code location, so it is sealed
# by the app's own signature rather than needing one of its own. Nothing below
# signs these, and nothing should.
#
# This runs before the freshness check on purpose: it is two file copies, and
# making it conditional on the expensive embed being stale is how the licence
# text goes missing from a bundle nobody rebuilt from scratch.
: "${UNLOCALIZED_RESOURCES_FOLDER_PATH:?must run from an Xcode Run Script phase}"
RESOURCES="${TARGET_BUILD_DIR}/${UNLOCALIZED_RESOURCES_FOLDER_PATH}"
FFMPEG_DIR="$(dirname "${FFMPEG_SRC}")"
mkdir -p "${RESOURCES}"
for licence in COPYING.LGPLv2.1 FFMPEG-SOURCE.txt; do
  # build-ffmpeg.sh always writes these next to the binary it produces, so an
  # ffmpeg without them means the binary came from somewhere else. That is the
  # precise situation the LGPL obligation exists for, so it is fatal.
  [[ -f "${FFMPEG_DIR}/${licence}" ]] \
    || die "build/ffmpeg/${licence} is missing next to the ffmpeg binary. Rebuild with ./scripts/build-ffmpeg.sh — never hand-place an ffmpeg."
  cp -f "${FFMPEG_DIR}/${licence}" "${RESOURCES}/${licence}"
done
note "staged FFmpeg licence text into Contents/Resources"

# ------------------------------------------------------------ skip if current
# Signing rewrites the embedded copies, so they can never be compared against
# the source tree after the fact - the freshness check must run BEFORE the
# copy, against the sources. "Current" = stamp exists, nothing in the source
# trees is newer than it, and the file counts still match (catches deletions,
# which -newer alone would miss).
STAMP="${TEMP_DIR:-${TARGET_BUILD_DIR}}/embed-helpers-signed.stamp"
if [[ -f "${STAMP}" && -d "${DEST}/helper" && -f "${DEST}/ffmpeg" ]]; then
  newer="$(find "${HELPER_SRC}" "${FFMPEG_SRC}" -newer "${STAMP}" -print 2>/dev/null | head -1)"
  src_count="$(find "${HELPER_SRC}" -type f ! -name '*.pdb' | wc -l | tr -d ' ')"
  dest_count="$(find "${DEST}/helper" -type f | wc -l | tr -d ' ')"
  if [[ -z "${newer}" && "${src_count}" == "${dest_count}" ]]; then
    note "embedded helpers current - skipping copy and re-sign"
    exit 0
  fi
fi
rm -f "${STAMP}"

# ---------------------------------------------------------------------- embed
# --delete keeps the tree an exact mirror; .pdb files are debug artifacts that
# would otherwise need signing (docs/signing.md §5).
mkdir -p "${DEST}"
rsync -a --delete --exclude '*.pdb' "${HELPER_SRC}/" "${DEST}/helper/"
cp -f "${FFMPEG_SRC}" "${DEST}/ffmpeg"

# ----------------------------------------------------------------------- sign
if [[ "${CODE_SIGNING_ALLOWED:-YES}" == "NO" ]]; then
  note "CODE_SIGNING_ALLOWED=NO - embedded helpers left unsigned"
  exit 0
fi

IDENTITY="${EXPANDED_CODE_SIGN_IDENTITY:--}"
TIMESTAMP_FLAG="--timestamp=none"
[[ "${CONFIGURATION:-Debug}" == "Release" ]] && TIMESTAMP_FLAG="--timestamp"

sign() {
  local entitlements="$1" target="$2"
  local args=(--force --sign "${IDENTITY}" --options runtime "${TIMESTAMP_FLAG}")
  [[ -n "${entitlements}" ]] && args+=(--entitlements "${entitlements}")
  codesign "${args[@]}" "${target}" 2>&1 | grep -v "replacing existing signature" || true
}

# Same rule as scripts/sign.sh: EVERY file under the embedded trees gets
# signed, whatever its type, deepest first. Entitlements are per-process, so
# only native Mach-O executables in helper/ carry helper.entitlements; ffmpeg
# is hardened-runtime with NO entitlements (it does not JIT); dylibs and
# managed assemblies carry none.
count=0
entitled=0
while IFS= read -r f; do
  [[ -n "${f}" && -f "${f}" ]] || continue
  ent=""
  if file -b "${f}" | grep -q 'Mach-O.*executable'; then
    [[ "${f}" == "${DEST}/helper/"* ]] && { ent="${HELPER_ENTITLEMENTS}"; entitled=$(( entitled + 1 )); }
  fi
  sign "${ent}" "${f}"
  count=$(( count + 1 ))
done < <(
  { find "${DEST}/helper" -type f; echo "${DEST}/ffmpeg"; } \
  | awk '{ depth = gsub(/\//, "/"); print depth "\t" $0 }' \
  | sort -rn \
  | cut -f2-
)

touch "${STAMP}"
note "embedded and signed ${count} files (${entitled} with helper entitlements)"
