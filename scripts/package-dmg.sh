#!/usr/bin/env bash
#
# package-dmg.sh — build the release disk image from a signed, stapled app.
#
# The app MUST already be signed, notarized and stapled before it goes in
# (docs/signing.md §7). Stapling the app as well as the DMG is what lets a
# user's first launch succeed with no network round trip, once they have
# dragged the app out of the image.
#
#   ./scripts/package-dmg.sh                    # build only
#   ./scripts/package-dmg.sh --sign             # + codesign the image
#   ./scripts/package-dmg.sh --sign --notarize  # + notarize and staple it
#
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DMG_DIR="$REPO/scripts/dmg"
APP="${APP:-$REPO/build/Oxbow.app}"
FFMPEG_DIR="${FFMPEG_DIR:-$REPO/build/ffmpeg}"
NOTARY_PROFILE="${NOTARY_PROFILE:-oxbow-notary}"
BACKGROUND="${BACKGROUND:-background.tiff}"

do_sign=false
do_notarize=false
for arg in "$@"; do
    case "$arg" in
        --sign)     do_sign=true ;;
        --notarize) do_sign=true; do_notarize=true ;;
        *) echo "unknown option: $arg" >&2; exit 2 ;;
    esac
done

command -v dmgbuild >/dev/null || {
    echo "dmgbuild not found. Install it with:  pip3 install dmgbuild" >&2
    exit 1
}

[[ -d "$APP" ]] || { echo "no app bundle at $APP" >&2; exit 1; }

# ------------------------------------------------------------------ version

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \
    "$APP/Contents/Info.plist")"
OUT="$REPO/build/Oxbow-$VERSION-arm64.dmg"

# ------------------------------------------------------------------ preflight

# Not fatal — you may legitimately want an unstapled image to test the layout —
# but shipping one means every user's first launch needs a network round trip.
if ! xcrun stapler validate "$APP" >/dev/null 2>&1; then
    echo "WARNING: $APP is not stapled. Notarize and staple it first." >&2
fi

# ------------------------------------------------------------------ staging

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

mkdir "$STAGE/Licenses"
for f in COPYING.LGPLv2.1 FFMPEG-SOURCE.txt; do
    [[ -f "$FFMPEG_DIR/$f" ]] || { echo "missing $FFMPEG_DIR/$f" >&2; exit 1; }
    cp "$FFMPEG_DIR/$f" "$STAGE/Licenses/"
done

# The volume icon is the app's own icon, taken from the bundle so there is no
# second copy in the repo to fall out of date.
ICNS="$(find "$APP/Contents/Resources" -maxdepth 1 -name '*.icns' | head -1)"
[[ -n "$ICNS" ]] || { echo "no .icns in $APP/Contents/Resources" >&2; exit 1; }
cp "$ICNS" "$DMG_DIR/VolumeIcon.icns"

# ------------------------------------------------------------------ build

rm -f "$OUT"
dmgbuild \
    -s "$DMG_DIR/settings.py" \
    -D app="$APP" \
    -D licenses="$STAGE/Licenses" \
    -D resources="$DMG_DIR" \
    -D background="$BACKGROUND" \
    "Oxbow" "$OUT"

echo "built $OUT ($(du -h "$OUT" | cut -f1))"

# ------------------------------------------------------------------ sign

if $do_sign; then
    IDENTITY="${SIGN_IDENTITY:-Developer ID Application}"
    codesign --sign "$IDENTITY" --timestamp --force "$OUT"
    codesign --verify --strict --verbose=2 "$OUT"
    echo "signed $OUT"
fi

if $do_notarize; then
    xcrun notarytool submit "$OUT" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$OUT"
    xcrun stapler validate "$OUT"
    spctl -a -vvv -t open --context context:primary-signature "$OUT"
    echo "notarized and stapled $OUT"
fi
