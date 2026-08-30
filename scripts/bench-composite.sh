#!/usr/bin/env bash
#
# Measure a machine's composite encode ceiling, in output megapixels per second.
#
# `docs/composite-performance.md` established that the composite step is bound
# by the throughput of Apple's hardware H.264 encoder, and §5 turned that into
# a formula that predicts any job's wall clock from one constant:
#
#   composite minutes ≈ out_w × out_h × fps × duration ÷ CEILING ÷ 60
#
# That constant was measured on one machine — an M1 Max, at ~750 Mpx/s — and
# §8 warned it is hardware-specific. This script is §8's "reproducing this"
# section made runnable, so the constant can be measured on any Mac rather
# than assumed from that one.
#
# It runs the two probes that matter and reports the ratio between them:
#
#   decode floor  decode both inputs, setpts/fps/hstack, encode nothing
#   composite     the app's exact argv, output discarded
#
# The ratio is the diagnosis, and it is why both probes are here rather than
# just the second one:
#
#   composite >> floor   encoder-bound. §6's conclusions hold, the reported
#                        ceiling is the encoder's, and only output pixel rate
#                        (§7) moves wall clock on this machine.
#   composite ≈ floor    decode-bound. This machine is in a regime the spike
#                        never measured, the reported ceiling is a lower bound
#                        rather than the encoder's, and §4.1 — piping raw chat
#                        frames, worth exactly 0s on an M1 Max — is worth
#                        re-measuring here before it is trusted as dead.
#
# Nothing is written to disk. The composite's output goes to /dev/null, which
# is valid only because the app already muxes fragmented MP4
# (`+frag_keyframe+empty_moov+default_base_moof`, docs/design/
# fragmented-output.md) and so never seeks backwards in its own output. That
# keeps this measuring the encoder rather than the disk while leaving the argv
# identical to production, which is the point.
#
# The bitrate is fixed at the app's 10 Mbps floor and is deliberately not a
# flag: §4.4 measured `-b:v 2M` against `-b:v 10M` at a 0.6% difference. Cost
# is per output pixel, not per bit.
#
# Inputs are a job's own intermediates — a real VOD and a real chat render, at
# the geometry `CompositeGeometry` derived for them. On a machine running the
# released app they live here, for as long as the job is unfinished:
#
#   ~/Library/Application Support/studio.lofti.Oxbow/workspace/jobs/*/artifacts/
#
# Both passes read `SECONDS_OF_CONTENT` seconds, default 300, because the
# numbers that matter are rates: a slice measures the same ceiling as a full
# VOD and bounds the run. On a six-hour job the composite pass would otherwise
# take the same hour-plus the app takes, which is the thing being diagnosed.
# Set it to 0 to read the whole source.
#
# Usage:
#   ./scripts/bench-composite.sh <video> <chatrender> [ffmpeg]
#   SECONDS_OF_CONTENT=600 ./scripts/bench-composite.sh <video> <chatrender>
#
# `ffmpeg` defaults to the repo's build output, then the installed app — so
# this runs on a machine that has only Oxbow.app and no checkout, which is
# exactly where a second data point is most likely to come from.
#
set -euo pipefail

die() { printf 'bench-composite: %s\n' "$*" >&2; exit 1; }

[ $# -ge 2 ] || die "usage: $0 <video> <chatrender> [ffmpeg]"

VIDEO=$1
CHAT=$2
FFMPEG=${3:-}

if [ -z "$FFMPEG" ]; then
  for candidate in \
    "$(dirname "$0")/../build/ffmpeg/ffmpeg" \
    "/Applications/Oxbow.app/Contents/MacOS/ffmpeg"
  do
    [ -x "$candidate" ] && { FFMPEG=$candidate; break; }
  done
fi

[ -n "$FFMPEG" ] && [ -x "$FFMPEG" ] || die "no ffmpeg; pass one as the third argument"
[ -f "$VIDEO" ] || die "no such file: $VIDEO"
[ -f "$CHAT" ] || die "no such file: $CHAT"

LIMIT=${SECONDS_OF_CONTENT:-300}
# Applied per input, before the filter graph, so it bounds decode as well as
# encode. `-t` after the inputs would bound only the output and leave the
# decode floor reading the whole file.
CAP=()
[ "$LIMIT" -gt 0 ] && CAP=(-t "$LIMIT")

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# Geometry comes from FFmpeg's own stderr banner, not ffprobe: the bundled
# build is configured `--disable-ffprobe` (docs/ffmpeg.md §2), so on the
# machines this most needs to run on there is no ffprobe to call.
#
# Parsing the resolution off that line has two traps, and a bare
# `[0-9]+x[0-9]+` walks into the second one:
#
#   Stream #0:0[0x1](und): Video: h264 (High) (avc1 / 0x31637661), \
#     yuv420p(progressive), 360x1080, 4092 kb/s, 30 fps, 30 tbr, 15360 tbn
#
# The `[0x1]` stream identifier matches it first and yields `0x1`. (The
# `[SAR 1:1 DAR 16:9]` field that appears on some inputs is harmless by
# comparison — it separates its numbers with `:`.) So the resolution is taken
# as a whole comma-separated *field*, anchored, with two digits minimum on
# each side: the identifier is neither at the start of a field nor two digits
# wide, so both properties have to fail at once for this to go wrong again.
banner() {
  "$FFMPEG" -hide_banner -i "$1" -f null - </dev/null 2>&1 | grep -m1 'Video:' || true
}

VIDEO_LINE=$(banner "$VIDEO")
CHAT_LINE=$(banner "$CHAT")

geometry() {
  printf '%s' "$1" | tr ',' '\n' \
    | grep -oE '^ *[0-9]{2,}x[0-9]{2,}' | head -1 | tr -d ' '
}

VIDEO_GEOM=$(geometry "$VIDEO_LINE")
CHAT_GEOM=$(geometry "$CHAT_LINE")
[ -n "$VIDEO_GEOM" ] || die "could not read the video's dimensions"
[ -n "$CHAT_GEOM" ] || die "could not read the chat render's dimensions"

VIDEO_W=${VIDEO_GEOM%x*}; VIDEO_H=${VIDEO_GEOM#*x}
CHAT_W=${CHAT_GEOM%x*};   CHAT_H=${CHAT_GEOM#*x}

# hstack requires equal heights and fails loudly if they differ — exit 234 and
# a 0-byte output (CompositeGeometry §2). Catching it here names the actual
# problem instead of leaving FFmpeg to report it as a filter error.
[ "$VIDEO_H" = "$CHAT_H" ] \
  || die "heights differ ($VIDEO_H vs $CHAT_H); these two files are not a composite pair"

# The video's rate, not the chat's. The chat is rendered at the video's rate or
# half it and the composite normalises it back up, so the output's frame rate
# is always the video's. This is `request.framerate` in ArgumentBuilder.
FPS_RAW=$(printf '%s' "$VIDEO_LINE" | grep -oE '[0-9]+(\.[0-9]+)? fps' | head -1 | cut -d' ' -f1)
[ -n "$FPS_RAW" ] || die "could not read the video's frame rate"

# Rounded, never truncated. FFmpeg reports NTSC rates as 59.94 and 29.97, and
# truncating those gives 59 and 29 — rates the app never uses. `request.
# framerate` comes from `CompositeGeometry.framerate(fromName:)`, which reads
# the integer out of a quality name like `1080p60`, so 60 is what production
# stacks at and 60 is what this has to stack at to be measuring the same
# thing. Truncation also costs real accuracy in the ceiling below, since the
# output frame count is 1.7% off.
FPS=$(printf '%s\n' "$FPS_RAW" | awk '{printf "%d", $1 + 0.5}')

OUT_W=$((VIDEO_W + CHAT_W))
FILTER="[0:v]setpts=PTS-STARTPTS[v];[1:v]setpts=PTS-STARTPTS,fps=${FPS}[c];[v][c]hstack=inputs=2[out]"

printf 'ffmpeg      %s\n' "$FFMPEG"
printf 'video       %sx%s @ %s\n' "$VIDEO_W" "$VIDEO_H" "$FPS"
printf 'chat        %sx%s\n' "$CHAT_W" "$CHAT_H"
printf 'output      %sx%s @ %s\n\n' "$OUT_W" "$VIDEO_H" "$FPS"

# Whole seconds. Both probes run for tens of seconds at minimum — a 48s job
# was the spike's own shortest — so ±1s is well inside the noise the spike
# itself saw between repeats (48.11s to 48.88s). BSD `date` has no %N and
# `EPOCHREALTIME` needs bash 5, which macOS's own /bin/bash is not.
now() { date +%s; }

# `-progress pipe:1` on the decode pass, for the duration. Deriving it here
# rather than probing is not cleverness: there is no ffprobe, and this pass
# has to walk every frame anyway. `out_time_us`, NOT `out_time_ms` — FFmpeg's
# `out_time_ms` is actually microseconds, the same trap FFmpegProgressParser
# documents.
printf 'decode floor  ... '
FLOOR_START=$(now)
"$FFMPEG" -nostdin -hide_banner ${CAP[@]+"${CAP[@]}"} -i "$VIDEO" ${CAP[@]+"${CAP[@]}"} -i "$CHAT" \
  -filter_complex "$FILTER" -map '[out]' -an \
  -progress pipe:1 -nostats -loglevel error \
  -f null - >"$WORK/progress" 2>"$WORK/floor.err" \
  || { cat "$WORK/floor.err" >&2; die "the decode pass failed"; }
FLOOR=$(( $(now) - FLOOR_START ))
printf '%ss\n' "$FLOOR"

DURATION_US=$(grep '^out_time_us=' "$WORK/progress" | tail -1 | cut -d= -f2)
[ -n "$DURATION_US" ] && [ "$DURATION_US" -gt 0 ] 2>/dev/null \
  || die "could not read the source duration from -progress output"

printf 'composite     ... '
TOTAL_START=$(now)
"$FFMPEG" -nostdin -y -hide_banner ${CAP[@]+"${CAP[@]}"} -i "$VIDEO" ${CAP[@]+"${CAP[@]}"} -i "$CHAT" \
  -filter_complex "$FILTER" -map '[out]' -an \
  -c:v h264_videotoolbox -b:v 10M -pix_fmt yuv420p \
  -nostats -loglevel error \
  -movflags '+frag_keyframe+empty_moov+default_base_moof' \
  -f mp4 /dev/null 2>"$WORK/total.err" \
  || { cat "$WORK/total.err" >&2; die "the composite pass failed"; }
TOTAL=$(( $(now) - TOTAL_START ))
printf '%ss\n\n' "$TOTAL"

[ "$TOTAL" -gt 0 ] && [ "$FLOOR" -gt 0 ] \
  || die "a pass finished in under a second; use a longer source"

python3 - "$OUT_W" "$VIDEO_H" "$FPS" "$FLOOR" "$TOTAL" "$DURATION_US" <<'PY'
import sys

w, h, fps, floor, total, duration_us = (int(a) for a in sys.argv[1:7])
duration = duration_us / 1e6

# Output pixels per second of *content*, which is what §5's formula takes.
rate = w * h * fps
# Output pixels per second of *wall clock*, which is the encoder's ceiling.
ceiling = rate * duration / total

print(f"source duration     {duration:.0f}s of content")
print(f"output pixel rate   {rate / 1e6:.1f} Mpx per second of content")
print()
print(f"realtime multiple   {duration / total:.2f}x")
print(f"encoder ceiling     {ceiling / 1e6:.0f} Mpx/s")
print()
print("predicts, via docs/composite-performance.md §5:")
print(f"  composite minutes ≈ out_w × out_h × fps × seconds ÷ {ceiling/1e6:.0f}e6 ÷ 60")
print()

ratio = total / floor
if ratio >= 1.4:
    verdict = ("ENCODER-BOUND — docs/composite-performance.md applies as written. "
               "The ceiling above is the encoder's, and only §7's output-pixel "
               "levers move wall clock on this machine.")
elif ratio <= 1.15:
    verdict = ("DECODE-BOUND — outside the regime the spike measured. The ceiling "
               "above is a lower bound, not the encoder's. §4.1 (piping raw chat "
               "frames) scored 0s on an M1 Max only because chat decode hid behind "
               "the encoder; re-measure it here before trusting that verdict.")
else:
    verdict = ("MIXED — neither term dominates, so a change to either would show up. "
               "Re-run under no other load before concluding anything from it.")

print(f"composite / floor   {ratio:.2f}x")
print()
print(verdict)
PY
