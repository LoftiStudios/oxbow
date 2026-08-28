#!/usr/bin/env bash
#
# Measure line coverage over Sources/OxbowKit and fail if it drops below a
# floor.
#
# Scope is deliberately OxbowKit and nothing else. OxbowKit is the queue
# engine, the argument builder, the output parser, and the persistence layer —
# the part with 365 tests and the part where a regression is silent. The
# SwiftUI layer has close to no automated coverage and is verified by hand, so
# folding it in would blend a well-tested engine with untested views into one
# number that means nothing and moves for the wrong reasons. A coverage
# measurement that spans both is worse than no measurement, because it looks
# like a fact.
#
# This runs off `swift test`, so it needs only Xcode — no .NET, no FFmpeg, no
# submodule. That matches the fast path in CONTRIBUTING.md: a contributor who
# can run the tests can run this.
#
# There is no coverage service and no badge behind this on purpose. What is
# actually useful on a pull request is "did this change stop testing
# something", and a floor plus the per-file table in the job summary answers
# that without a third-party app holding write access to the repository.
#
# Usage:
#   ./scripts/coverage.sh                  run tests, report, enforce the floor
#   ./scripts/coverage.sh --floor 92       override the floor for one run
#   ./scripts/coverage.sh --no-test        reuse the profdata already on disk
#   ./scripts/coverage.sh --lcov cov.info  also write an lcov file
#
set -euo pipefail

# The floor is line coverage over Sources/OxbowKit, as a percentage.
#
# It sits a few points under the real number rather than at it. A floor set to
# whatever today's coverage happens to be turns every honest refactor into a
# red build and teaches people to raise the floor without reading why it moved,
# which is the failure mode that makes coverage gates worthless. This is a
# regression alarm: it should fire when a file lands with no tests, not when a
# well-tested function loses two lines. Raise it deliberately, in its own
# commit, when the real number has held above a higher mark for a while.
FLOOR=90

RUN_TESTS=1
LCOV_OUT=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --floor)   FLOOR="${2:?--floor needs a number}"; shift 2 ;;
    --no-test) RUN_TESTS=0; shift ;;
    --lcov)    LCOV_OUT="${2:?--lcov needs a path}"; shift 2 ;;
    -h|--help) sed -n '2,29p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *)         echo "unknown option: $1" >&2; exit 2 ;;
  esac
done

cd "$(dirname "$0")/.."

# Test sources and anything under .build are not the thing being measured.
# OxbowKit has no external package dependencies today, but the .build clause
# keeps that true if one is ever added.
IGNORE='(Tests/|\.build/)'

if [[ $RUN_TESTS -eq 1 ]]; then
  swift test --enable-code-coverage
else
  # Still needed: --show-bin-path is cheap, but the caller may have built with
  # a different configuration and we should fail loudly rather than report on
  # stale data.
  swift build --build-tests --enable-code-coverage >/dev/null
fi

BIN="$(swift build --enable-code-coverage --show-bin-path)"
PROFDATA="$BIN/codecov/default.profdata"

# The test bundle's executable, not the bundle directory. Globbed rather than
# hardcoded so a rename of the package does not silently break this into a
# "0% coverage" pass.
shopt -s nullglob
BUNDLES=("$BIN"/*.xctest)
shopt -u nullglob

if [[ ${#BUNDLES[@]} -ne 1 ]]; then
  echo "coverage: expected exactly one .xctest bundle in $BIN, found ${#BUNDLES[@]}" >&2
  exit 1
fi

TESTBIN="${BUNDLES[0]}/Contents/MacOS/$(basename "${BUNDLES[0]}" .xctest)"

for f in "$PROFDATA" "$TESTBIN"; do
  [[ -e "$f" ]] || { echo "coverage: missing $f — run without --no-test" >&2; exit 1; }
done

echo
xcrun llvm-cov report "$TESTBIN" \
  -instr-profile "$PROFDATA" \
  -ignore-filename-regex="$IGNORE"

if [[ -n "$LCOV_OUT" ]]; then
  xcrun llvm-cov export "$TESTBIN" \
    -instr-profile "$PROFDATA" \
    -ignore-filename-regex="$IGNORE" \
    -format=lcov > "$LCOV_OUT"
  echo "coverage: wrote $LCOV_OUT"
fi

SUMMARY_JSON="$(xcrun llvm-cov export -summary-only "$TESTBIN" \
  -instr-profile "$PROFDATA" \
  -ignore-filename-regex="$IGNORE")"

# python3 rather than jq: jq is not on a stock Mac, python3 comes with the
# Command Line Tools that `swift test` already requires. FLOOR is passed in
# the environment, never interpolated into the program text.
read -r PCT LINES COVERED FUNCS FUNCPCT REGIONPCT <<EOF
$(printf '%s' "$SUMMARY_JSON" | python3 -c '
import json, sys
t = json.load(sys.stdin)["data"][0]["totals"]
print(t["lines"]["percent"], t["lines"]["count"], t["lines"]["covered"],
      t["functions"]["count"], t["functions"]["percent"], t["regions"]["percent"])
')
EOF

printf '\ncoverage: %.2f%% of %s lines in Sources/OxbowKit (floor %s%%)\n' \
  "$PCT" "$LINES" "$FLOOR"

# GitHub renders this under the job in the Actions UI, which is where a
# reviewer will actually look. Absent locally, so the redirect is guarded.
if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
  {
    echo "### OxbowKit coverage"
    echo
    printf '| | Covered | Total | |\n|---|--:|--:|--:|\n'
    printf '| Lines | %s | %s | **%.2f%%** |\n' "$COVERED" "$LINES" "$PCT"
    printf '| Functions | — | %s | %.2f%% |\n' "$FUNCS" "$FUNCPCT"
    printf '| Regions | — | — | %.2f%% |\n' "$REGIONPCT"
    echo
    printf 'Floor is %s%% line coverage. Scope is `Sources/OxbowKit`; the SwiftUI layer is not measured.\n' "$FLOOR"
    echo
    echo '<details><summary>Per-file</summary>'
    echo
    echo '```'
    xcrun llvm-cov report "$TESTBIN" \
      -instr-profile "$PROFDATA" \
      -ignore-filename-regex="$IGNORE"
    echo '```'
    echo
    echo '</details>'
  } >> "$GITHUB_STEP_SUMMARY"
fi

# bash cannot compare decimals; python3 returns the verdict as an exit status.
if ! PCT="$PCT" FLOOR="$FLOOR" python3 -c '
import os, sys
sys.exit(0 if float(os.environ["PCT"]) >= float(os.environ["FLOOR"]) else 1)
'; then
  printf 'coverage: FAILED — %.2f%% is below the %s%% floor\n' "$PCT" "$FLOOR" >&2
  echo 'coverage: add tests for the lines this change left uncovered, or, if the' >&2
  echo '          floor is genuinely wrong now, move it in its own commit and say why.' >&2
  exit 1
fi

echo "coverage: OK"
