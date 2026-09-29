#!/usr/bin/env bash
#
# Compare two chat renders frame by frame, using the bundled CLI as the
# reference implementation.
#
# `docs/design/native-chat-render.md` proposes a Swift chat renderer that reads
# the CLI's own chat JSON and writes the file the composite already reads. The
# whole design rests on being able to answer "does this match?" mechanically,
# and the CLI is the only reference there is. This script is that comparison,
# and §8's first instruction is to run it against the CLI alone — before there
# is any Swift — because two runs of the CLI are how both of the corrections
# below were found.
#
# Two things make a naive comparison useless, both measured 2026-09-17:
#
#   Username colours are not stable between renders. A viewer with no Twitch
#   colour is drawn from a palette indexed by a per-process-randomised string
#   hash, so two renders of one file differ in 98% of frames for no reason
#   (docs/upstream-candidates.md §1). `prepare` pins them.
#
#   A chat download is not reproducible either: messages sharing a second AND a
#   millisecond come back in arbitrary order (native-chat-render.md §8.1). So
#   everything here starts from ONE saved JSON. Never compare two downloads.
#
# Renders are written losslessly (ffv1/bgra) rather than through
# h264_videotoolbox, so a differing frame is the renderer's doing and not the
# encoder's. VideoToolbox was measured as frame-stable anyway — identical
# decoded frames from differing file bytes — but a lossless intermediate keeps
# the question separate from the answer.
#
# Usage:
#   ./scripts/compare-chat-render.sh selftest <chat.json>
#       Pin colours, render twice with the CLI, and report differing frames.
#       Expect 0. Anything else means the oracle moved and nothing built on
#       top of it can be trusted yet.
#
#   ./scripts/compare-chat-render.sh offline <chat.json>
#       Render an embedded (-E) chat both ways — CLI fetching from the network,
#       and CLI --offline from the embedded images — and compare. Expect 0.
#       This is what justifies embedding at all (§3.1).
#
#   ./scripts/compare-chat-render.sh prepare <chat.json> <fixed.json>
#   ./scripts/compare-chat-render.sh render  <chat.json> <out.mkv> [--online]
#   ./scripts/compare-chat-render.sh diff    <a.mkv> <b.mkv> [frame]
#       The pieces, for comparing a native renderer's output against a CLI
#       render: `render` the reference, produce the candidate however, `diff`
#       the two. `diff` also writes a side-by-side difference image for one
#       frame, which is how a colour problem was told apart from a layout one.
#
# Geometry defaults to what CompositeGeometry derives for a 1920x1080 source
# (docs/design/compositing.md §4) and is overridable:
#
#   WIDTH=342 HEIGHT=1026 FRAMERATE=30 FONT_SIZE=15 FONT="Inter Embedded"
#
# The helper and FFmpeg default to the repo's build output. Emote images are
# cached under a temp directory per run; `offline` deliberately uses a fresh
# one, because the CLI will otherwise read a provider list an earlier run left
# behind and "offline" proves nothing.
#
set -euo pipefail

die() { printf 'compare-chat-render: %s\n' "$*" >&2; exit 1; }
note() { printf 'compare-chat-render: %s\n' "$*" >&2; }

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
HELPER=${HELPER:-$ROOT/build/helper/TwitchDownloaderCLI}
FFMPEG=${FFMPEG:-$ROOT/build/ffmpeg/ffmpeg}
WIDTH=${WIDTH:-342}
HEIGHT=${HEIGHT:-1026}
FRAMERATE=${FRAMERATE:-30}
FONT_SIZE=${FONT_SIZE:-15}
FONT=${FONT:-Inter Embedded}

[ -x "$HELPER" ] || die "no helper at $HELPER — build it, or set HELPER"
[ -x "$FFMPEG" ] || die "no ffmpeg at $FFMPEG — build it, or set FFMPEG"

# Pin every null user_color to one value. Without this, 98% of frames differ
# between two renders of the same file and the comparison says nothing.
prepare() {
  local input=$1 output=$2
  [ -f "$input" ] || die "no such file: $input"
  python3 - "$input" "$output" <<'PY'
import json, sys
src, dst = sys.argv[1], sys.argv[2]
with open(src) as f:
    chat = json.load(f)
pinned = 0
for comment in chat["comments"]:
    if not comment["message"].get("user_color"):
        comment["message"]["user_color"] = "#FF69B4"
        pinned += 1
with open(dst, "w") as f:
    json.dump(chat, f)
embedded = chat.get("embeddedData") or {}
print(f"{len(chat['comments'])} comments, {pinned} colours pinned, "
      f"{len(embedded.get('thirdParty', []))} third-party emotes embedded")
PY
}

# One lossless CLI render. Offline unless --online is passed, with its own
# empty cache directory so "offline" means it.
render() {
  local input=$1 output=$2 mode=${3:-} temp
  [ -f "$input" ] || die "no such file: $input"
  temp=$(mktemp -d "${TMPDIR:-/tmp}/compare-chat-render.XXXXXX")
  trap 'rm -rf "$temp"' RETURN

  # `${offline[@]+...}` rather than a plain `"${offline[@]}"`: macOS ships bash
  # 3.2, where an empty array counts as unset and `set -u` aborts the run. The
  # empty case is the --online one, so the naive form fails only on the render
  # that reaches the network.
  local offline=(--offline)
  [ "$mode" = "--online" ] && offline=()

  "$HELPER" chatrender --banner=false --collision Overwrite \
    -i "$input" -o "$output" --temp-path "$temp" --ffmpeg-path "$FFMPEG" \
    -w "$WIDTH" -h "$HEIGHT" --framerate "$FRAMERATE" \
    --font-size "$FONT_SIZE" -f "$FONT" \
    --background-color "#111111" --alt-background-color "#191919" \
    --message-color "#ffffff" --outline-size 4 \
    --dispersion ${offline[@]+"${offline[@]}"} \
    '--output-args=-c:v ffv1 -pix_fmt bgra "{save_path}"' >/dev/null
}

hashes() {
  "$FFMPEG" -v error -i "$1" -f framemd5 - | grep -v '^#' | awk -F, '{print $6}'
}

# Differing frame count, plus a difference image for one frame. Lossless in,
# so any difference is real; `blend=difference` amplified 8x is what told a
# username colour apart from a layout shift when this was first run by hand.
diff_renders() {
  local a=$1 b=$2 frame=${3:-} differing total
  for f in "$a" "$b"; do [ -f "$f" ] || die "no such file: $f"; done

  hashes "$a" > "$a.md5"
  hashes "$b" > "$b.md5"
  total=$(wc -l < "$a.md5" | tr -d ' ')
  [ "$total" = "$(wc -l < "$b.md5" | tr -d ' ')" ] \
    || note "frame counts differ: $total vs $(wc -l < "$b.md5" | tr -d ' ')"
  differing=$(paste -d' ' "$a.md5" "$b.md5" | awk '$1!=$2' | wc -l | tr -d ' ')

  printf '%s differing frames of %s\n' "$differing" "$total"

  if [ "$differing" != "0" ]; then
    # Default to the first differing frame rather than a fixed one: on a
    # 5,400-frame render, picking blind usually lands somewhere uninformative.
    # No `exit` in the awk: it would close the pipe, take `paste` down with
    # SIGPIPE, and `set -o pipefail` would then abandon the whole comparison
    # silently at exactly the point where it has something to show.
    [ -n "$frame" ] || frame=$(paste -d' ' "$a.md5" "$b.md5" \
      | awk '$1!=$2 && !seen {print NR-1; seen=1}')
    local out="${a%.mkv}-vs-$(basename "${b%.mkv}")-f$frame"
    # No PNG encoder in our LGPL FFmpeg build; PPM and sips get there.
    "$FFMPEG" -v error -y -i "$a" -i "$b" -filter_complex \
      "[0:v]select=eq(n\,$frame),format=rgb24,split[a][a2];\
       [1:v]select=eq(n\,$frame),format=rgb24,split[b][b2];\
       [a][b]blend=all_mode=difference,lutrgb=r=val*8:g=val*8:b=val*8[d];\
       [a2][b2][d]hstack=inputs=3" -frames:v 1 -c:v ppm "$out.ppm"
    sips -s format png "$out.ppm" --out "$out.png" >/dev/null 2>&1 \
      && rm -f "$out.ppm" && note "difference image: $out.png (A | B | diff x8)"
  fi
}

[ $# -ge 2 ] || die "usage: $0 {selftest|offline|prepare|render|diff} ..."
command=$1
shift

case "$command" in
  prepare)
    [ $# -eq 2 ] || die "usage: $0 prepare <chat.json> <fixed.json>"
    prepare "$1" "$2"
    ;;

  render)
    [ $# -ge 2 ] || die "usage: $0 render <chat.json> <out.mkv> [--online]"
    render "$1" "$2" "${3:-}"
    ;;

  diff)
    [ $# -ge 2 ] || die "usage: $0 diff <a.mkv> <b.mkv> [frame]"
    diff_renders "$1" "$2" "${3:-}"
    ;;

  selftest)
    [ $# -eq 1 ] || die "usage: $0 selftest <chat.json>"
    work=$(mktemp -d "${TMPDIR:-/tmp}/compare-chat-selftest.XXXXXX")
    note "working in $work"
    prepare "$1" "$work/fixed.json"
    note "rendering twice — a heavy 3-minute window takes about 30s each"
    render "$work/fixed.json" "$work/a.mkv"
    render "$work/fixed.json" "$work/b.mkv"
    result=$(diff_renders "$work/a.mkv" "$work/b.mkv")
    printf 'selftest: %s\n' "$result"
    case "$result" in
      "0 differing "*) note "the CLI reproduces itself; it can be used as a reference" ;;
      *) die "the reference is not reproducible — see native-chat-render.md §8.1 before trusting any comparison built on it" ;;
    esac
    ;;

  offline)
    [ $# -eq 1 ] || die "usage: $0 offline <chat.json>   (the json must have been downloaded with -E)"
    python3 -c "
import json, sys
chat = json.load(open(sys.argv[1]))
embedded = chat.get('embeddedData') or {}
if not embedded.get('thirdParty') and not embedded.get('firstParty'):
    sys.exit('no embeddedData — re-download with -E')
" "$1" || die "input has no embedded images"
    work=$(mktemp -d "${TMPDIR:-/tmp}/compare-chat-offline.XXXXXX")
    note "working in $work"
    prepare "$1" "$work/fixed.json"
    python3 -c "
import json, sys
chat = json.load(open(sys.argv[1]))
chat.pop('embeddedData', None)
json.dump(chat, open(sys.argv[2], 'w'))
" "$work/fixed.json" "$work/stripped.json"
    note "rendering offline from embedded images, then online from the network"
    render "$work/fixed.json" "$work/offline.mkv"
    render "$work/stripped.json" "$work/online.mkv" --online
    printf 'offline vs online: %s\n' "$(diff_renders "$work/offline.mkv" "$work/online.mkv")"
    ;;

  *)
    die "unknown command: $command"
    ;;
esac
