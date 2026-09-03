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
#   ./scripts/screenshots.sh --no-shadow      transparent window edges, for a
#                                        design tool that adds its own shadow
#   ./scripts/screenshots.sh --no-trim        intake with Trim collapsed
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
# Whether macOS draws its own window shadow into the capture's alpha.
#
# Keep it for compositing here: it is the real shadow, and the front window's
# falls on the one behind it for free. Drop it when the captures are going into
# a design tool, which wants clean transparent window edges and its own shadow
# layer -- a baked-in shadow cannot be moved, recoloured, or removed there.
SHADOW=1
# Whether the intake opens with its Trim section down. Both sections open is a
# 1002pt-tall sheet; closing Trim takes 100pt off it, which matters a lot when
# the composite is a wide frame.
TRIM=1
while [[ $# -gt 0 ]]; do
  case "$1" in
    --no-build) BUILD=0; shift ;;
    --keep)     KEEP=1; shift ;;
    --size)     SIZE="${2:?--size needs WIDTHxHEIGHT, e.g. 900x520}"; shift 2 ;;
    --no-shadow) SHADOW=0; shift ;;
    --no-trim)   TRIM=0; shift ;;
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
  [[ -n "${SERVER_PID:-}" ]] && kill "$SERVER_PID" 2>/dev/null || true
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
LINK=""
[[ -f "$FIXTURE/link.txt" ]] && LINK="$(cat "$FIXTURE/link.txt")"
INFO_JOB=""
[[ -f "$FIXTURE/infojob.txt" ]] && INFO_JOB="$(cat "$FIXTURE/infojob.txt")"

cp -f "$FIXTURE/videoinfo.json" "$STATE/" 2>/dev/null || true

# The intake's thumbnail has to arrive over HTTP. VideoCard.loadImage requires
# an HTTPURLResponse with status 200, and a file:// URL produces a plain
# URLResponse — so it would load nothing and quietly draw the placeholder,
# which looks like a design decision rather than a broken fixture. A loopback
# server costs one process and keeps the app unchanged.
PORT=$(( 8730 + RANDOM % 200 ))
python3 -m http.server "$PORT" --bind 127.0.0.1 --directory "$FIXTURE" >/dev/null 2>&1 &
SERVER_PID=$!

echo "launching with OXBOW_FIXTURE_DIR=$STATE  size=$SIZE  thumbs=:$PORT"
# `-key value` pairs land in NSArgumentDomain, which outranks everything in
# UserDefaults. That is how the intake is kept off the developer's own saved
# defaults -- destination, quality cap, chat size -- without writing to the
# real domain the way `defaults write` would. `intakeOptionsExpanded` is a
# genuine preference, so this is also how the Download Options section is
# opened; the trim section is not one, and comes in by environment.
OXBOW_FIXTURE_DIR="$STATE" \
OXBOW_FIXTURE_EXPAND="$EXPAND" \
OXBOW_FIXTURE_SIZE="$SIZE" \
OXBOW_FIXTURE_LINK="$LINK" \
OXBOW_FIXTURE_TRIM="$TRIM" \
OXBOW_FIXTURE_THUMBS="http://127.0.0.1:$PORT" \
OXBOW_FIXTURE_INFO_JOB="$INFO_JOB" \
  "$APP/Contents/MacOS/Oxbow" \
  -hasSavedDefaults NO \
  -intakeOptionsExpanded YES \
  >/dev/null 2>&1 &
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
  # The shadow is kept -- no `-o`. These are composited onto a desktop
  # background, and macOS drawing its own window shadow into the alpha beats
  # any approximation of one: the capture grows by 224px on each axis and
  # carries the real falloff. It also means the front window's shadow lands on
  # the one behind it for free, because it is part of that window's own PNG.
  # `screencapture` exits non-zero with "could not create image from window"
  # when it is not allowed to record the screen. Caught here rather than left
  # to `set -e`, which would abort the run with only that line -- and the
  # blank-file check further down, which is the other half of this, never gets
  # reached because no file is written at all.
  # Branch rather than build an argv array: macOS ships bash 3.2, where
  # "${array[@]}" on an empty array trips `set -u`.
  local rc=0
  if [[ $SHADOW -eq 1 ]]; then
    screencapture -x -l"$id" "$out" || rc=$?
  else
    screencapture -x -o -l"$id" "$out" || rc=$?
  fi
  if [[ $rc -ne 0 ]]; then
    permission_help "screencapture could not capture window $id (exit $rc)."
  fi
  echo "  $out  (window $id)"
}

# Components, deliberately -- docs/screenshot.png is composited from these by
# hand and is not written here. A run that overwrote the hero image would undo
# that composite every time somebody regenerated a part of it.
OUT="$ROOT/docs/screenshots"
permission_help() {
  echo >&2
  echo "$1" >&2
  echo >&2
  echo "This is almost always Screen Recording permission. macOS grants it to" >&2
  echo "the application running this script, not to the script, so a terminal" >&2
  echo "that has never been granted it will fail here even though another one" >&2
  echo "on the same Mac succeeds." >&2
  echo >&2
  echo "  System Settings > Privacy & Security > Screen & System Audio Recording" >&2
  echo >&2
  echo "Add (or tick) the app you ran this from -- Terminal, iTerm, your editor," >&2
  echo "whatever hosts the shell -- then QUIT AND REOPEN it. The permission is" >&2
  echo "read at launch, so a running app keeps being refused until it restarts." >&2
  exit 1
}

mkdir -p "$OUT"
# Let the titles settle before matching any of them. A WindowGroup(for:) window
# carries the application name until its content sets a title, so capturing too
# early can match Job Info as "Oxbow".
sleep 2
echo "capturing…"
capture "Oxbow" "$OUT/queue.png"
capture "Add Download" "$OUT/intake.png"
# Job Info's window title is the job's own title, so match the fixture's
# mid-flight row rather than a fixed string.
capture "${EXPAND:0:24}" "$OUT/info.png"

# Guard against the silent failure mode: without Screen Recording permission
# screencapture writes a file, it is just empty or black.
for f in "$OUT/queue.png" "$OUT/intake.png" "$OUT/info.png"; do
  bytes=$(stat -f%z "$f" 2>/dev/null || echo 0)
  if [[ "$bytes" -lt 20000 ]]; then
    permission_help "$(basename "$f") is only ${bytes} bytes — almost certainly blank."
  fi
done

echo "done. docs/screenshot.png is the composite and is not written by this."
