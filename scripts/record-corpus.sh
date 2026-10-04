#!/usr/bin/env bash
# Records real programs through vthost into Packages/DeathRaceKit/Tests/Fixtures/corpus/:
# NAME.bin is the program's output, NAME.screen the screen VTCore makes of it (80x24). The
# corpus tests replay every .bin and compare with its .screen, so a change that alters how real
# programs look shows up as a failing test.
#
#   scripts/record-corpus.sh             record everything again, then write the goldens
#   scripts/record-corpus.sh --goldens   rewrite the goldens from the existing recordings,
#                                        after a deliberate engine change (review the diff!)
#
# Recordings depend on the programs' versions, so they are recorded once and checked in;
# re-recording is for adding programs, not for routine runs. Needs vim, nvim, less, tmux,
# htop, nano and fzf.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
PKG=$ROOT/Packages/DeathRaceKit
CORPUS=$PKG/Tests/Fixtures/corpus
swift build --package-path "$PKG" --product vthost >/dev/null
VTHOST="$(swift build --package-path "$PKG" --show-bin-path)/vthost"

goldens() {
  for bin in "$CORPUS"/*.bin; do
    "$VTHOST" replay --columns 80 --rows 24 "$bin" > "${bin%.bin}.screen"
  done
  echo "wrote $(ls "$CORPUS"/*.screen | wc -l) goldens"
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
  "$VTHOST" run --columns 80 --rows 24 --record "$CORPUS/$name.bin" "$@" >/dev/null || true
  echo "recorded $name ($(wc -c < "$CORPUS/$name.bin") bytes)"
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
goldens
