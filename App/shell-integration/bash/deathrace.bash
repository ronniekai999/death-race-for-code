# Death Race for Code — bash.
#
# Sourced from your ~/.bashrc, by one line this app offers to add and shows you first. bash is
# the one shell we ask about, because the two ways to reach it without touching your files
# both change its startup semantics: --rcfile replaces your rc rather than adding to it, and
# BASH_ENV applies to non-interactive shells too.
#
# What this reports is the same as the other two:
#   OSC 133;A  prompt start      OSC 133;B  prompt end (appended to PS1)
#   OSC 633;E  the command line  OSC 133;C  output start
#   OSC 133;D;<exit>;dur=<ms>
#
# On macOS's own /bin/bash, which is 3.2 from 2007, there is no $EPOCHREALTIME and so no
# duration — marks and exit codes still work. Homebrew's bash 5 reports everything. We do not
# fork a `date` per prompt to paper over it: this app does not spend a process on a status
# line and should not spend one on a badge.

if [ -n "${BASH_VERSION-}" ] && [[ $- == *i* ]] && [ -z "${__deathrace_installed-}" ]; then
  __deathrace_installed=1
  __deathrace_started=
  __deathrace_ran=
  # Empty, not 1: the DEBUG trap below fires for every command, and the rest of this very
  # file counts. Starting armed made the first command it reported be a line of its own
  # source. The first real prompt arms it.
  __deathrace_at_prompt=

  # `;` would end the parameter and `\` is the escape itself; a line break and a tab are
  # spelled out so a command written across two lines stays one line of text. Parameter
  # expansion only: this runs on every command you type.
  __deathrace_escape() {
    local text=${1//\\/\\\\}
    text=${text//;/\\x3b}
    text=${text//$'\n'/\\x0a}
    text=${text//$'\r'/\\x0d}
    text=${text//$'\t'/\\x09}
    printf '%s' "$text"
  }

  # DEBUG fires before every command, including the ones inside this file and inside
  # PROMPT_COMMAND. The flag is what makes it fire once per command you actually typed.
  __deathrace_debug() {
    [ -n "$__deathrace_at_prompt" ] || return 0
    __deathrace_at_prompt=
    __deathrace_ran=1
    __deathrace_started=${EPOCHREALTIME-}
    printf '\e]633;E;%s\a' "$(__deathrace_escape "$BASH_COMMAND")"
    printf '\e]133;C\a'
  }

  __deathrace_prompt() {
    local ended=$?
    if [ -n "$__deathrace_ran" ]; then
      local duration=
      if [ -n "$__deathrace_started" ] && [ -n "${EPOCHREALTIME-}" ]; then
        # Whole and fractional parts separately, in integer arithmetic: bash has no floats,
        # and $EPOCHREALTIME is seconds with six decimal places. `10#` forces base ten, or a
        # fraction like 012345 would be read as octal — and 098765 would be a syntax error.
        local from_s=${__deathrace_started%.*} from_us=${__deathrace_started#*.}
        local to_s=${EPOCHREALTIME%.*} to_us=${EPOCHREALTIME#*.}
        local ms=$(( (to_s - from_s) * 1000 + (10#$to_us - 10#$from_us) / 1000 ))
        [ "$ms" -lt 0 ] && ms=0
        duration=";dur=$ms"
      fi
      printf '\e]133;D;%d%s\a' "$ended" "$duration"
    fi
    __deathrace_started=
    __deathrace_ran=
    __deathrace_at_prompt=1
    printf '\e]133;A\a'
    return $ended
  }

  trap '__deathrace_debug' DEBUG
  # Appended, never assigned, so whatever already sets your prompt keeps working.
  case "${PROMPT_COMMAND-}" in
    *__deathrace_prompt*) ;;
    "") PROMPT_COMMAND='__deathrace_prompt' ;;
    *) PROMPT_COMMAND="${PROMPT_COMMAND%;};__deathrace_prompt" ;;
  esac

  # B marks the end of the prompt, so it goes in the prompt. \[...\] tells bash the bytes
  # take no columns, without which every prompt would be mismeasured.
  case "$PS1" in
    *133\;B*) ;;
    *) PS1="${PS1}\[\e]133;B\a\]" ;;
  esac
fi
