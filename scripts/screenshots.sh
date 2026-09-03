#!/usr/bin/env bash
#
# Regenerate the screenshots the project publishes, from a checked-in fixture.
#
# docs/screenshot.png is a release artifact — it goes stale every time the
# interface moves, and it is the first thing anyone sees on the README. The way
# it used to be produced was to point Oxbow at real VODs and photograph the
# result, which put real streamers' names, titles and thumbnails into an image
# published on a public repository. That is a permission question, and it is
# not one anybody should have to answer again for every release.
#
# So: launch the real app against a fabricated queue and capture its window.
#
# Nothing here knows anything about layout. It knows a window title and a JSON
# file, which is what makes it survive the interface changes it exists to keep
# up with. If a view is restyled, rerun this; if a window is renamed, change one
# string below.
#
# The state redirect is `OXBOW_FIXTURE_DIR`, honoured by
# `AppComposition.defaultSupportDirectory()` in DEBUG builds only. See
# `Oxbow/ScreenshotFixture.swift` for why it is not in release builds.
#
# Requires Screen Recording permission for whatever terminal runs this —
# `screencapture` cannot capture another app's window without it, and the first
# run will produce a black or empty image rather than an error if it is
# missing. The check below turns that into a real message.
#
# Usage:
#   ./scripts/screenshots.sh             build if needed, capture, write to docs/
#   ./scripts/screenshots.sh --no-build  reuse the existing Debug build
#   ./scripts/screenshots.sh --keep      leave the app running to poke at
#   ./scripts/screenshots.sh --size 900x560   window content size, in points
#                                        (default 900x492 — what docs/ holds)
#
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$(pwd)"

BUILD=1
KEEP=0
# Window content size in points. Frame restoration would otherwise hand the
# run whatever size the developer last left their real Oxbow window at, so the
# screenshot would be a different shape on every machine. How much room sits
# under the last row is a design call, so it is an input.
SIZE="900x492"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --no-build) BUILD=0; shift ;;
    --keep)     KEEP=1; shift ;;
    --size)     SIZE="${2:?--size needs WIDTHxHEIGHT, e.g. 900x520}"; shift 2 ;;
    -h|--help)  sed -n '2,32p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *)          echo "unknown option: $1" >&2; exit 2 ;;
  esac
done

FIXTURE="$ROOT/scripts/screenshots/fixture"
[[ -f "$FIXTURE/queue.json" ]] || {
  echo "no fixture at $FIXTURE/queue.json — run scripts/screenshots/make-fixture.py" >&2
  exit 1
}

DERIVED="$ROOT/build/screenshots-derived"

if [[ $BUILD -eq 1 ]]; then
  echo "building (Debug — the fixture hook is #if DEBUG)…"
  xcodebuild build \
    -project Oxbow.xcodeproj \
    -scheme Oxbow \
    -configuration Debug \
    -derivedDataPath "$DERIVED" \
    CODE_SIGNING_ALLOWED=NO \
    >/dev/null
fi

APP="$DERIVED/Build/Products/Debug/Oxbow.app"
[[ -d "$APP" ]] || { echo "no app at $APP — run without --no-build" >&2; exit 1; }

# A copy, so the app's own writes (it rewrites queue.json on load-time
# reconciliation) never dirty the checked-in fixture.
STATE="$(mktemp -d)"
cp "$FIXTURE/queue.json" "$STATE/queue.json"

cleanup() {
  [[ $KEEP -eq 1 ]] && { echo "app left running; state in $STATE"; return; }
  [[ -n "${APP_PID:-}" ]] && kill "$APP_PID" 2>/dev/null || true
  rm -rf "$STATE"
}
trap cleanup EXIT

# Which row opens its step list. Expansion is view state, not queue state, so
# it cannot live in queue.json; make-fixture.py writes this beside it so the
# two cannot drift.
EXPAND=""
[[ -f "$FIXTURE/expand.txt" ]] && EXPAND="$(cat "$FIXTURE/expand.txt")"

echo "launching with OXBOW_FIXTURE_DIR=$STATE  size=$SIZE"
OXBOW_FIXTURE_DIR="$STATE" OXBOW_FIXTURE_EXPAND="$EXPAND" OXBOW_FIXTURE_SIZE="$SIZE" \
  "$APP/Contents/MacOS/Oxbow" >/dev/null 2>&1 &
APP_PID=$!

# Capture one window by title. Retries because the window arrives a moment
# after the process does, and SwiftUI needs a beat to lay it out.
#
# Matched by PID, never by application name. This run launches a *second*
# Oxbow next to whatever the developer already has open — running the
# executable directly bypasses LaunchServices, so it is a genuinely separate
# process. Matching on the name found the developer's real window first and
# captured a queue full of real streamers, and the image looked entirely
# correct, which is the worst way for this to go wrong.
capture() {
  local title="$1" out="$2" id=""
  for _ in $(seq 1 40); do
    if id="$(swift "$ROOT/scripts/screenshots/window-id.swift" "$APP_PID" "$title" 2>/dev/null)"; then
      [[ -n "$id" ]] && break
    fi
    sleep 0.5
  done
  [[ -n "$id" ]] || {
    echo "never found a window titled \"$title\" for pid $APP_PID" >&2
    swift "$ROOT/scripts/screenshots/window-id.swift" "$APP_PID" "$title" || true
    return 1
  }
  # One more beat: the window exists but its content may still be arriving.
  sleep 1.5
  # -o drops the drop-shadow, leaving transparent rounded corners that read
  # correctly on both a light and a dark README background.
  screencapture -x -o -l"$id" "$out"
  echo "  $out  (window $id)"
}

mkdir -p "$ROOT/docs"
echo "capturing…"
capture "Oxbow" "$ROOT/docs/screenshot.png"

# Guard against the silent failure mode: without Screen Recording permission
# screencapture writes a file, it is just empty or black.
SIZE=$(stat -f%z "$ROOT/docs/screenshot.png" 2>/dev/null || echo 0)
if [[ "$SIZE" -lt 20000 ]]; then
  echo >&2
  echo "capture is only ${SIZE} bytes — almost certainly blank." >&2
  echo "Grant Screen Recording to this terminal in System Settings >" >&2
  echo "Privacy & Security > Screen Recording, then run this again." >&2
  exit 1
fi

echo "done."
