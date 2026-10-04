#!/usr/bin/env bash
# Runs esctest2 against VTCore, with vthost as the terminal, and compares the failing tests
# with the checked-in list of known failures. Fails on a new failure and on an unexpected
# pass, so the list only ever shrinks on purpose.
#
#   scripts/esctest.sh                    run and compare
#   scripts/esctest.sh --update           run and rewrite the known-failures list
#   scripts/esctest.sh --include REGEX    run only matching tests (no comparison)
#
# esctest is GPL-2.0, so it is fetched at a pinned commit and never vendored. It needs
# python3 and git.
set -euo pipefail

ESCTEST_REPO=https://github.com/ThomasDickey/esctest2.git
ESCTEST_COMMIT=2798f12149a19c3295e9b4853ab2da4b2eff1b2b

ROOT=$(cd "$(dirname "$0")/.." && pwd)
PKG=$ROOT/Packages/DeathRaceKit
KNOWN=$PKG/Tests/Fixtures/esctest-known-failures.txt
WORK=$PKG/.build/esctest
LOG=$WORK/esctest.log

update=false
include=".*"
while [ $# -gt 0 ]; do
  case "$1" in
    --update) update=true ;;
    --include) include="$2"; shift ;;
    *) echo "usage: $0 [--update] [--include REGEX]" >&2; exit 2 ;;
  esac
  shift
done

mkdir -p "$WORK"
if [ "$(git -C "$WORK/esctest2" rev-parse HEAD 2>/dev/null || true)" != "$ESCTEST_COMMIT" ]; then
  rm -rf "$WORK/esctest2"
  git clone --quiet "$ESCTEST_REPO" "$WORK/esctest2"
  git -C "$WORK/esctest2" checkout --quiet "$ESCTEST_COMMIT"
fi

# vthost's speed does not matter here (esctest waits on itself), so the debug build that CI
# already has will do.
CONFIG=${CONFIG:-debug}
swift build --package-path "$PKG" -c "$CONFIG" --product vthost >/dev/null
VTHOST="$(swift build --package-path "$PKG" -c "$CONFIG" --show-bin-path)/vthost"

# esctest resets the terminal to 80x25 before every test. It reads the screen through
# DECRQCRA, which only vthost --checksums answers; the app never does. We test against
# current xterm: erased cells read as spaces (--xterm-checksum 334) and mode 45 reverse-wraps
# only soft-wrapped lines, with 1045 for the old behavior (--xterm-reverse-wrap 383).
# xtermWinopsEnabled: without it, esctest expects xterm to fail the tests that need window
# operations and files those failures as known xterm bugs. With it, our deliberate refusals
# (title and clipboard reads) count as the failures they are, and what we do pass (DECNCSM)
# counts as a pass.
rm -f "$LOG"
"$VTHOST" run --columns 80 --rows 25 --checksums -- \
  python3 "$WORK/esctest2/esctest/esctest.py" \
    --expected-terminal xterm --xterm-checksum 334 --xterm-reverse-wrap 383 --max-vt-level 5 \
    --options xtermWinopsEnabled \
    --timeout 0.5 --no-print-logs --logfile "$LOG" --include "$include" || true

summary=$(grep -E '^\*\*\* ' "$LOG" | tail -1 || true)
if [ -z "$summary" ]; then
  echo "esctest did not finish; the last lines of its log:" >&2
  tail -20 "$LOG" >&2 || true
  exit 1
fi
echo "esctest: ${summary//\*/}"

failing=$(sed -n '/^Failing tests:$/,$p' "$LOG" | tail -n +2 | grep -E '^[A-Za-z0-9_]+\.test_' | sort -u || true)

if [ "$include" != ".*" ]; then
  [ -n "$failing" ] && printf '%s\n' "$failing"
  exit 0
fi

if $update; then
  {
    echo "# esctest2 $ESCTEST_COMMIT tests that fail against VTCore today."
    echo "# Written by scripts/esctest.sh --update; CI fails when this list is wrong in either direction."
    [ -n "$failing" ] && printf '%s\n' "$failing"
  } > "$KNOWN"
  echo "wrote $(printf '%s' "$failing" | grep -c . || true) known failures to ${KNOWN#"$ROOT"/}"
  exit 0
fi

known=$(grep -v '^#' "$KNOWN" 2>/dev/null | sort -u || true)
new_failures=$(comm -13 <(printf '%s\n' "$known") <(printf '%s\n' "$failing") | grep . || true)
new_passes=$(comm -23 <(printf '%s\n' "$known") <(printf '%s\n' "$failing") | grep . || true)
status=0
if [ -n "$new_failures" ]; then
  echo "New failures (fix them, or if intended, run scripts/esctest.sh --update):"
  printf '  %s\n' $new_failures
  status=1
fi
if [ -n "$new_passes" ]; then
  echo "Now passing (run scripts/esctest.sh --update to lock them in):"
  printf '  %s\n' $new_passes
  status=1
fi
[ $status -eq 0 ] && echo "esctest matches the known-failures list."
exit $status
