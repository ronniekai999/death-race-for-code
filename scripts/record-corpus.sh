#!/usr/bin/env bash
# Records real programs through vthost into Packages/DeathRaceKit/Tests/Fixtures/corpus/:
# NAME.bin is the program's output, NAME.marks how much of it came before each scripted key
# press, and NAME.screen the screens VTCore makes of it (80x24): one at every key press, then
# the last. The corpus tests replay every .bin and compare with its .screen, so a change that
# alters how real programs look shows up as a failing test. A few recordings also get a frame
# golden in Tests/Fixtures/frames/: the colors the app would draw, with the default theme.
#
#   scripts/record-corpus.sh             record everything again, then write the goldens
#   scripts/record-corpus.sh --goldens   rewrite the goldens from the existing recordings,
#                                        after a deliberate engine change (review the diff!)
#
# Recordings depend on the programs' versions, so they are recorded once and checked in;
# re-recording is for adding programs, not for routine runs. Needs vim, nvim, less, tmux,
# htop, nano, fzf and vttest.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
PKG=$ROOT/Packages/DeathRaceKit
CORPUS=$PKG/Tests/Fixtures/corpus
FRAMES=$PKG/Tests/Fixtures/frames
FRAME_GOLDENS="htop vim-syntax tmux-split less-search vttest-colors"
swift build --package-path "$PKG" --product vthost >/dev/null
VTHOST="$(swift build --package-path "$PKG" --show-bin-path)/vthost"

goldens() {
  for bin in "$CORPUS"/*.bin; do
    local marks=()
    [ -f "${bin%.bin}.marks" ] && marks=(--marks "${bin%.bin}.marks")
    "$VTHOST" replay --columns 80 --rows 24 "${marks[@]}" "$bin" > "${bin%.bin}.screen"
  done
  mkdir -p "$FRAMES"
  for name in $FRAME_GOLDENS; do
    local marks=()
    [ -f "$CORPUS/$name.marks" ] && marks=(--marks "$CORPUS/$name.marks")
    "$VTHOST" frame --summary --columns 80 --rows 24 "${marks[@]}" "$CORPUS/$name.bin" > "$FRAMES/$name.frame"
  done
  echo "wrote $(ls "$CORPUS"/*.screen | wc -l) screen goldens and $(ls "$FRAMES"/*.frame | wc -l) frame goldens"
}

if [ "${1:-}" = "--goldens" ]; then goldens; exit 0; fi

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"; tmux -L vtcorpus kill-server 2>/dev/null || true' EXIT
cd "$WORK"
printf 'one\ntwo\nthree\n' > notes.txt
cat > sample.c <<'C'
#include <stdio.h>

/* Legends never die. */
static int race(int laps) {
    int total = 0;
    for (int lap = 1; lap <= laps; lap++) {
        total += lap * 999;
    }
    return total;
}

int main(void) {
    printf("%d\n", race(3));
    return 0;
}
C
for i in $(seq 1 60); do echo "line $i of a long file, with a needle on line 42" | sed "s/line 42/line $i/" ; done > long.txt
printf '中文字符 日本語 한국어\ncafé naïve résumé — “quotes”\n👍🏽 👨‍👩‍👧 🇺🇸 ❤️ ✦ 999\ne\xcc\x81 a\xcc\x8a combining\n' > unicode.txt

record() {
  local name=$1; shift
  "$VTHOST" run --columns 80 --rows 24 --record "$CORPUS/$name.bin" --marks "$CORPUS/$name.marks" "$@" \
    >/dev/null || true
  [ -s "$CORPUS/$name.marks" ] || rm -f "$CORPUS/$name.marks"
  echo "recorded $name ($(wc -c < "$CORPUS/$name.bin") bytes)"
}

# vttest, the classic VT100/VT220 test, menu by menu. Every screen it draws says what it should
# look like, and each golden was checked against that. vttest is told the truth about the
# width (24x80.80: programs cannot switch the window to 132 columns here), so its 132-column
# passes run at 80. Left out: what needs double-size lines, VT52 or 8-bit and national
# character sets (not in v1), the keyboard tests, and reports vttest waits for and we do not
# send (ENQ answerback, DECREQTPARM, which a VT220 does not answer either).
vttest() {
  local name=$1; shift
  local keys=()
  for k in "$@"; do keys+=(--keys "$k"); done
  record "$name" "${keys[@]}" -- vttest 24x80.80
}

export LANG=C.UTF-8
record vim-edit --keys 'jA and more\e' --keys ':set number\r' -- vim -u NONE -i NONE -N notes.txt
record vim-syntax --keys 'G' --keys 'gg' -- vim -u NONE -i NONE -N -c 'syntax on' -c 'set number' sample.c
record less-search --keys '/needle\r' --keys 'G' -- less long.txt
record nvim-split --keys ':set number cursorline\r' --keys ':vsplit notes.txt\r' -- nvim --clean -n sample.c
# A plain prompt and a fixed status line, so the screen does not carry this machine's name,
# directory or clock.
# (tmux starts panes through a non-interactive shell, which drops PS1 from the environment,
# so the prompt comes from an rcfile.)
echo "PS1='\$ '" > bashrc
cat > tmux.conf <<TMUX
set -g status-right '999'
set -g default-command 'bash --rcfile $WORK/bashrc --noprofile'
TMUX
record tmux-split --keys 'echo left\r' --keys '\x02%' --keys 'printf "\\033[1;35mright\\033[0m\\n"\r' \
  --keys '\x02"' --keys 'echo bottom\r' -- tmux -L vtcorpus -f tmux.conf new-session
tmux -L vtcorpus kill-server 2>/dev/null || true
# htop lists only itself: exec keeps the shell's PID, so -p $$ names htop's own process.
record htop --keys '' -- bash -c 'exec htop -p $$'
# fzf's inline mode draws with relative cursor moves below wherever the cursor is.
record fzf-inline --keys '42' -- bash -c 'seq 1 500 | fzf --height=12 --border --no-mouse'
record nano-edit --keys 'Hello from nano\r' --keys '\x0b' -- nano -I notes.txt
record unicode-cat -- cat unicode.txt

n() { local i; for i in $(seq 1 "$1"); do printf '%s\n' '\r'; done; }
# Menu 1: cursor movements. Menu 2: screen features. Menu 3: the VT100 character sets, SI/SO.
mapfile -t six < <(n 6); vttest vttest-cursor '1\r' "${six[@]}"
mapfile -t fifteen < <(n 15); vttest vttest-screen '2\r' "${fifteen[@]}"
vttest vttest-charsets '3\r' '8\r' '\r' '9\r' '\r'
# Menu 6: status and attribute reports. Menu 8: VT102 insert and delete.
vttest vttest-reports '6\r' '3\r' '\r' '4\r' '\r' '5\r' '\r' '6\r' '\r'
mapfile -t fourteen < <(n 14); vttest vttest-insdel '8\r' "${fourteen[@]}"
# Menu 9: wrap-around with cursor addressing.
vttest vttest-wrap '9\r' '7\r' '\r'
# Menu 11: VT220 reports and screen display; ISO 6429 cursor movement, REP, SD, SU and colors;
# xterm's alternate screens.
vttest vttest-vt220 '11\r' '1\r' '1\r' '1\r' '1\r' '\r' '2\r' '\r' '3\r' '\r' '4\r' '\r' '0\r' '0\r' \
  '2\r' '2\r' '\r' '\r' '3\r' '\r' '4\r' '\r' '\r'
mapfile -t nine < <(n 9)
vttest vttest-iso6429 '11\r' '5\r' '*\r' "${nine[@]}" '0\r' '7\r' '2\r' '\r' '3\r' '\r' '6\r' '\r'
vttest vttest-colors '11\r' '6\r' '2\r' '\r' '3\r' '\r' '4\r' '\r' '\r' '5\r' '\r' '\r' '9\r' '\r' '\r' '\r'
vttest vttest-altscreen '11\r' '8\r' '7\r' '3\r' '\r' '\r' '\r' '4\r' '\r' '\r' '\r' '5\r' '\r' '\r' '\r'
goldens
