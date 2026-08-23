#!/usr/bin/env bash
#
# Sign an Oxbow app bundle inside-out with a Developer ID Application identity.
#
# Usage:
#   ./scripts/sign.sh path/to/Oxbow.app
#
# Environment:
#   IDENTITY  Signing identity. Defaults to the sole "Developer ID Application"
#             identity in the keychain; set explicitly if you have more than one.
#
# ---------------------------------------------------------------------------
# The rule this script exists to enforce
#
# EVERY file under Contents/MacOS must be signed, whatever its type. That
# directory is the bundle's code location, so codesign treats everything in it
# as a code object - not just Mach-O binaries, but .NET managed assemblies
# (PE32+, signed as Format=generic), .json runtime configs, and even .txt
# files. Miss one and bundle verification fails with:
#
#   code object is not signed at all
#   In subcomponent: .../Contents/MacOS/helper/COPYRIGHT.txt
#
# which is a notarization rejection waiting to happen. Signing only the Mach-O
# files is the intuitive approach and it is wrong.
#
# Two further rules:
#
#   - `codesign --deep` is deprecated and silently does the wrong thing for
#     SIGNING: it applies the same entitlements to every nested binary, which
#     is exactly backwards here since entitlements are per-process and the
#     helper needs its own. Never reintroduce it for signing. It is correct
#     and used below for VERIFYING.
#
#   - Signatures must be applied inside-out. Sealing a container records the
#     signatures of its contents, so anything signed afterwards invalidates it.
# ---------------------------------------------------------------------------
#
set -euo pipefail

BUNDLE="${1:-}"
[[ -n "${BUNDLE}" ]] || { echo "usage: $0 path/to/Oxbow.app" >&2; exit 2; }
[[ -d "${BUNDLE}" ]] || { echo "ERROR: no such bundle: ${BUNDLE}" >&2; exit 2; }
BUNDLE="${BUNDLE%/}"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_ENTITLEMENTS="${REPO_ROOT}/scripts/entitlements/app.entitlements"
HELPER_ENTITLEMENTS="${REPO_ROOT}/scripts/entitlements/helper.entitlements"

log() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
die() { printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

for f in "${APP_ENTITLEMENTS}" "${HELPER_ENTITLEMENTS}"; do
  [[ -f "${f}" ]] || die "Missing entitlements file: ${f}"
done

# ------------------------------------------------------------------- identity
if [[ -z "${IDENTITY:-}" ]]; then
  # macOS ships bash 3.2, which has no `mapfile`. Read into arrays the long way.
  found=()
  while IFS= read -r line; do
    [[ -n "${line}" ]] && found+=("${line}")
  done < <(security find-identity -v -p codesigning \
           | grep "Developer ID Application" \
           | sed -E 's/.*"(.*)"/\1/')
  case "${#found[@]}" in
    0) die "No 'Developer ID Application' identity in the keychain. Apple Development and Apple Distribution certificates CANNOT sign for distribution outside the App Store." ;;
    1) IDENTITY="${found[0]}" ;;
    *) printf 'Multiple Developer ID Application identities found:\n'
       printf '  %s\n' "${found[@]}"
       die "Set IDENTITY explicitly." ;;
  esac
fi
log "Identity: ${IDENTITY}"

sign() {
  local entitlements="$1" target="$2"
  local args=(--force --sign "${IDENTITY}" --options runtime --timestamp)
  [[ -n "${entitlements}" ]] && args+=(--entitlements "${entitlements}")
  codesign "${args[@]}" "${target}" 2>&1 | grep -v "replacing existing signature" || true
}

MAIN_EXECUTABLE="${BUNDLE}/Contents/MacOS/$(
  /usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "${BUNDLE}/Contents/Info.plist"
)"

# -------------------------------------------------------------------- hygiene
# Debug symbols are build artifacts. They bloat the bundle, and because they
# live under Contents/MacOS they would otherwise have to be signed for no
# benefit whatsoever.
pdb_count=0
while IFS= read -r pdb; do
  rm -f "${pdb}"
  pdb_count=$(( pdb_count + 1 ))
done < <(find "${BUNDLE}" -type f -name '*.pdb')
(( pdb_count > 0 )) && log "Removed ${pdb_count} .pdb debug symbol files"

# Executable code under Contents/Resources is a classic notarization rejection.
while IFS= read -r res; do
  die "Executable code in Contents/Resources: ${res}"$'\n'"Move it under Contents/MacOS."
done < <(
  find "${BUNDLE}/Contents/Resources" -type f -print0 2>/dev/null \
  | xargs -0 file --mime-type 2>/dev/null \
  | grep -E 'application/x-mach-binary$' \
  | grep -v ' (for architecture ' \
  | sed 's|:[[:space:]]*application/x-mach-binary$||'
)

# ------------------------------------------------------- collect nested code
# Everything under Contents/MacOS except the bundle's own main executable,
# deepest paths first so containers are always sealed after their contents.
nested=()
while IFS= read -r line; do
  [[ -n "${line}" && -f "${line}" ]] || continue
  [[ "${line}" == "${MAIN_EXECUTABLE}" ]] && continue
  nested+=("${line}")
done < <(
  find "${BUNDLE}/Contents/MacOS" -type f \
  | awk '{ depth = gsub(/\//, "/"); print depth "\t" $0 }' \
  | sort -rn \
  | cut -f2-
)

(( ${#nested[@]} > 0 )) || die "No nested files found under ${BUNDLE}/Contents/MacOS."

# ------------------------------------------------------------- sign inside-out
log "Signing ${#nested[@]} nested files under Contents/MacOS"
native_executables=0
entitled=0
for f in "${nested[@]}"; do
  # Entitlements are per-process, so only NATIVE executables can carry them.
  # Managed assemblies are never a process image (the CoreCLR host is), and
  # dylibs inherit the entitlements of whatever process loads them.
  #
  # Note `file` describes managed assemblies as "PE32+ executable", so the test
  # must require Mach-O explicitly rather than just matching "executable".
  #
  # Only the CoreCLR helper needs allow-jit. ffmpeg is a native executable that
  # does not JIT, so it gets the hardened runtime with NO entitlements -
  # granting it allow-jit anyway would weaken the bundle for nothing.
  ent=""
  if file -b "${f}" | grep -q 'Mach-O.*executable'; then
    native_executables=$(( native_executables + 1 ))
    if [[ "${f}" == "${BUNDLE}/Contents/MacOS/helper/"* ]]; then
      ent="${HELPER_ENTITLEMENTS}"
      entitled=$(( entitled + 1 ))
    fi
  fi
  sign "${ent}" "${f}"
done
log "Signed ${#nested[@]} files (${native_executables} native executables, ${entitled} with helper entitlements)"

log "Signing app bundle"
sign "${APP_ENTITLEMENTS}" "${BUNDLE}"

# ---------------------------------------------------------------------- verify
log "Verifying"
codesign --verify --deep --strict --verbose=2 "${BUNDLE}" 2>&1 \
  | grep -vE '^--(prepared|validated):' \
  | sed 's/^/  /'

# Belt and braces: --deep verification has been known to pass while an
# individual nested file is unsigned. Check directly.
unsigned=0
while IFS= read -r f; do
  [[ "${f}" == "${MAIN_EXECUTABLE}" ]] && continue
  codesign -v "${f}" >/dev/null 2>&1 || { echo "  UNSIGNED: ${f#${BUNDLE}/}"; unsigned=$(( unsigned + 1 )); }
done < <(find "${BUNDLE}/Contents/MacOS" -type f)
(( unsigned == 0 )) || die "${unsigned} file(s) under Contents/MacOS are unsigned."

log "Checking the helper carries its own entitlements"
helper_exe="${BUNDLE}/Contents/MacOS/helper/TwitchDownloaderCLI"
if [[ -f "${helper_exe}" ]]; then
  codesign -d --entitlements :- "${helper_exe}" 2>/dev/null | grep -q "allow-jit" \
    || die "Helper is missing allow-jit. Its OWN signature must carry it; the app's entitlements do not propagate to child processes."
  echo "  helper: allow-jit present"
fi

log "Done. Next: xcrun notarytool submit --keychain-profile oxbow-notary"
