#!/usr/bin/env bash
#
# Build the FFmpeg binary that Oxbow bundles.
#
# Produces an LGPL-2.1-or-later, arm64, statically-linked `ffmpeg` that depends
# on nothing outside macOS system frameworks. See docs/ffmpeg.md for why we
# build this ourselves instead of shipping a prebuilt binary.
#
# Usage:
#   ./scripts/build-ffmpeg.sh            # full LGPL build (default, ~20 MB)
#   MINIMAL=1 ./scripts/build-ffmpeg.sh  # trimmed component set (~6 MB)
#
set -euo pipefail

FFMPEG_VERSION="8.1.2"
FFMPEG_SHA256="464beb5e7bf0c311e68b45ae2f04e9cc2af88851abb4082231742a74d97b524c"
FFMPEG_URL="https://ffmpeg.org/releases/ffmpeg-${FFMPEG_VERSION}.tar.xz"

# MUST match the app's MACOSX_DEPLOYMENT_TARGET (macOS 26). A helper built for
# a newer minimum than the app fails to launch on the app's oldest supported OS.
MIN_MACOS="${MIN_MACOS:-26.0}"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK_DIR="${REPO_ROOT}/build/ffmpeg-src"
OUT_DIR="${REPO_ROOT}/build/ffmpeg"
TARBALL="${WORK_DIR}/ffmpeg-${FFMPEG_VERSION}.tar.xz"

log() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
die() { printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

[[ "$(uname -m)" == "arm64" ]] || die "This script builds arm64 only; running on $(uname -m)."

mkdir -p "${WORK_DIR}" "${OUT_DIR}"

# ---------------------------------------------------------------- fetch source
if [[ ! -f "${TARBALL}" ]]; then
  log "Downloading FFmpeg ${FFMPEG_VERSION}"
  curl -fsSL -o "${TARBALL}" "${FFMPEG_URL}"
fi

log "Verifying source checksum"
actual="$(shasum -a 256 "${TARBALL}" | awk '{print $1}')"
[[ "${actual}" == "${FFMPEG_SHA256}" ]] \
  || die "Checksum mismatch. Expected ${FFMPEG_SHA256}, got ${actual}."

SRC_DIR="${WORK_DIR}/ffmpeg-${FFMPEG_VERSION}"
rm -rf "${SRC_DIR}"
mkdir -p "${SRC_DIR}"
tar xf "${TARBALL}" -C "${SRC_DIR}" --strip-components=1

# ------------------------------------------------------------------- configure
#
# Licensing note: FFmpeg's configure defaults to LGPL 2.1+. We deliberately do
# NOT pass --enable-gpl (pulls in x264 and the GPL filters), --enable-nonfree,
# or --enable-version3. Do not add them. See docs/ffmpeg.md.
#
# --disable-autodetect is what makes this reproducible: without it, configure
# links against whatever Homebrew happens to have installed, which both breaks
# self-containment and can silently change the license surface.
#
CONFIGURE_FLAGS=(
  --prefix="${OUT_DIR}"
  --arch=arm64
  --disable-shared --enable-static
  --disable-autodetect
  --enable-videotoolbox --enable-audiotoolbox
  --enable-neon --enable-pthreads
  --disable-network          # Oxbow only ever feeds it local files and pipes
  --disable-doc --disable-debug
  --disable-ffplay --disable-ffprobe
  --extra-cflags="-arch arm64 -mmacosx-version-min=${MIN_MACOS}"
  --extra-ldflags="-arch arm64 -mmacosx-version-min=${MIN_MACOS}"
)

if [[ -n "${MINIMAL:-}" ]]; then
  log "Configuring MINIMAL component set"
  CONFIGURE_FLAGS+=(
    --disable-everything
    --enable-demuxer=concat,rawvideo,mpegts,mov,ffmetadata,matroska,image2,aac,mp3,wav
    --enable-decoder=rawvideo,h264,hevc,aac,mp3,pcm_s16le,png
    --enable-encoder=h264_videotoolbox,hevc_videotoolbox,aac,rawvideo,png
    # `ipod` is what an `.m4a` extension resolves to. ArgumentBuilder writes the
    # resume sidecar as `audio.m4a` with no `-f`, so without this a resumed
    # composite fails at muxer init on a MINIMAL build.
    --enable-muxer=mp4,mov,matroska,mpegts,rawvideo,image2,null,ipod
    --enable-parser=h264,hevc,aac,mpegaudio,png
    --enable-bsf=aac_adtstoasc,h264_mp4toannexb,hevc_mp4toannexb,extract_extradata
    --enable-filter=format,scale,null,copy,unsharp,setpts,fps,hstack,aformat,anull,aresample,atrim,trim,transpose,crop,pad
    --enable-protocol=file,pipe,fd,concat
  )
fi

log "Configuring (min macOS ${MIN_MACOS})"
( cd "${SRC_DIR}" && ./configure "${CONFIGURE_FLAGS[@]}" > "${WORK_DIR}/configure.log" 2>&1 ) \
  || { tail -30 "${WORK_DIR}/configure.log"; die "configure failed. Full log: ${WORK_DIR}/configure.log"; }

grep -q "^License: LGPL version 2.1 or later" "${WORK_DIR}/configure.log" \
  || die "Build is not LGPL 2.1. configure reported: $(grep -i '^License' "${WORK_DIR}/configure.log")"

# ----------------------------------------------------------------------- build
log "Building"
( cd "${SRC_DIR}" && make -j"$(sysctl -n hw.ncpu)" > "${WORK_DIR}/make.log" 2>&1 ) \
  || { tail -30 "${WORK_DIR}/make.log"; die "make failed. Full log: ${WORK_DIR}/make.log"; }

install -m 0755 "${SRC_DIR}/ffmpeg" "${OUT_DIR}/ffmpeg"
FFMPEG_BIN="${OUT_DIR}/ffmpeg"

# ---------------------------------------------------------------------- verify
log "Verifying"

[[ "$(lipo -archs "${FFMPEG_BIN}")" == "arm64" ]] \
  || die "Not a pure arm64 binary: $(lipo -archs "${FFMPEG_BIN}")"

# Anything outside /System/Library and /usr/lib means the binary is not
# self-contained and will not run on a machine without that library.
foreign="$(otool -L "${FFMPEG_BIN}" | tail -n +2 | awk '{print $1}' \
           | grep -vE '^(/System/Library/|/usr/lib/)' || true)"
[[ -z "${foreign}" ]] || die "Non-system dynamic dependencies found:"$'\n'"${foreign}"

config_line="$("${FFMPEG_BIN}" -hide_banner -version 2>/dev/null | grep '^configuration:')"
for forbidden in --enable-gpl --enable-nonfree --enable-version3; do
  grep -q -- "${forbidden}" <<<"${config_line}" && die "Binary was built with ${forbidden}."
done

"${FFMPEG_BIN}" -hide_banner -encoders 2>/dev/null | grep -q ' h264_videotoolbox' \
  || die "h264_videotoolbox encoder missing — hardware encoding would be unavailable."

"${FFMPEG_BIN}" -hide_banner -encoders 2>/dev/null | grep -q 'libx264' \
  && die "libx264 present — this is a GPL build."

# The chat renderer pipes raw frames in; the VOD finalizer concatenates parts;
# a resumed composite writes its audio sidecar to `audio.m4a`, which is `ipod`.
for component in "demuxers rawvideo" "demuxers concat" "demuxers ffmetadata" \
                 "demuxers mpegts" "muxers mp4" "muxers ipod" "protocols pipe"; do
  set -- ${component}
  "${FFMPEG_BIN}" -hide_banner -"$1" 2>/dev/null | grep -qE "(^| )$2( |$)" \
    || die "Required component missing: $2 ($1)"
done

# ------------------------------------------------------- licence compliance
log "Staging LGPL compliance files"
cp "${SRC_DIR}/COPYING.LGPLv2.1" "${OUT_DIR}/COPYING.LGPLv2.1"
cat > "${OUT_DIR}/FFMPEG-SOURCE.txt" <<EOF
The 'ffmpeg' binary distributed with Oxbow is unmodified FFmpeg ${FFMPEG_VERSION},
licensed under the GNU Lesser General Public License version 2.1 or later
(see COPYING.LGPLv2.1).

Source:   ${FFMPEG_URL}
SHA-256:  ${FFMPEG_SHA256}

It was configured with:

${config_line#configuration: --prefix=${OUT_DIR} }

To reproduce this binary, run scripts/build-ffmpeg.sh from the Oxbow repository.
(The --prefix is omitted above because it is a local path chosen by that script.)
EOF

size="$(du -h "${FFMPEG_BIN}" | awk '{print $1}')"
log "Done: ${FFMPEG_BIN} (${size}, LGPL 2.1+, arm64, system frameworks only)"
