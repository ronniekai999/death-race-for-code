# Death Race for Code — bash.
#
# Sourced from your own startup file, by one line this app offers to add and shows you first.
# bash is the one shell we ask about, because the two ways to reach it without touching your
# files both change what its startup means: --rcfile replaces your rc rather than adding to it,
# and BASH_ENV applies to non-interactive shells too.
#
# What this reports is the same as the other two:
#   OSC 133;A  prompt start      OSC 133;B  prompt end (appended to PS1)
#   OSC 633;E  the command line  OSC 133;C  output start
#   OSC 133;D;<exit>;dur=<ms>
#
# On macOS's own /bin/bash, which is 3.2 from 2007, there is no $EPOCHREALTIME and so no
# duration — the marks, the command line and its exit code still work. Homebrew's bash 5
# reports everything. We do not fork a `date` per prompt to paper over it: this app does not
# spend a process on a status line and should not spend one on a badge. For the same reason
# nothing below uses syntax newer than 3.2 understands, ${var@a} included: a parse error there
# would cost you the whole file rather than one feature.

if [ -n "${BASH_VERSION-}" ] && [[ $- == *i* ]]; then

  # The functions are defined once; the trap, PS1 and PROMPT_COMMAND are applied on every
  # load. That split is the fix for a real bug rather than tidiness: `source ~/.bashrc` runs
  # your rc again and reassigns both variables, and a guard that skipped everything on the
  # second load left a shell with our functions defined and nothing calling them.
  if [ -z "${__deathrace_installed-}" ]; then
    __deathrace_installed=1
    __deathrace_started=
    __deathrace_ran=
    __deathrace_ended=0
    __deathrace_command=
    __deathrace_history=
    __deathrace_escaped=
    # Empty, not 1: the DEBUG trap fires for every command, and the rest of this very file
    # counts. The end of the first real prompt arms it.
    __deathrace_at_prompt=

    # `;` would end the parameter and `\` is the escape itself; a line break, a carriage return
    # and a tab are spelled out so a command written across two lines stays one line of text.
    # The answer comes back in a variable rather than on stdout because $( ) is a fork, and
    # this runs on every command you type.
    __deathrace_escape() {
      local text=${1//\\/\\\\}
      text=${text//;/\\x3b}
      text=${text//$'\n'/\\x0a}
      text=${text//$'\r'/\\x0d}
      text=${text//$'\t'/\\x09}
      __deathrace_escaped=$text
    }

    # What you typed, from the history rather than from $BASH_COMMAND, which holds one simple
    # command at a time — so `echo a; echo b` arrived as `echo a` — and which shows an alias
    # already expanded rather than what you wrote. This is the one fork per command, and the
    # command line is what it buys; VS Code's integration and bash-preexec both pay it. The
    # number in front is cut off with [[ =~ ]] rather than a `sed`, so it stays the only one.
    __deathrace_typed() {
      local entry=
      entry=$(HISTTIMEFORMAT= builtin history 1 2>/dev/null)
      # The separator is matched exactly, not as `[[:space:]]+`: history prints `%5d%c %s`, so
      # after the number come the modified flag and one space, and a greedy class ate the
      # *typed* leading space along with them. That space is the oldest privacy convention
      # there is, and `CommandBests.isPrivate` is the thing reading it, so losing it here wrote
      # commands to bests.json and into notification banners that the user had asked to hide.
      if [[ $entry =~ ^[[:space:]]*([0-9]+)(\*|[[:space:]])[[:space:]] ]] &&
        [ "${BASH_REMATCH[1]}" != "$__deathrace_history" ]; then
        __deathrace_history=${BASH_REMATCH[1]}
        __deathrace_command=${entry#"${BASH_REMATCH[0]}"}
      elif [[ $HISTCONTROL == *ignorespace* || $HISTCONTROL == *ignoreboth* ]]; then
        # The history number did not advance and this shell is set to keep space-prefixed lines
        # out of history, so that is very likely what this line is. $BASH_COMMAND would answer
        # — and answer *without* the leading space, because it is rebuilt from the parsed
        # command — so the one signal that says "do not record this" would be gone and the line
        # would be kept and named anyway. Reporting no text at all is the honest answer: the
        # mark, the duration and the exit code still arrive, and an empty command is already
        # refused by `CommandBests.record`, named "A command" by Ring Ring, and left unsaveable
        # by "Save Last Command to Wishing Well".
        __deathrace_command=
      else
        # The newest entry is not this command and nothing was asked to be hidden, so what is
        # left is `ignoredups` (you repeated a command exactly: same text, so the only loss is
        # the tail of a compound line) or `set +o history` (nothing goes in at all). Reading
        # the entry anyway would put the *previous* command's text on this one, which is worse
        # than a short answer. $BASH_COMMAND is less — one simple command, aliases already
        # expanded, and no leading whitespace — but it is at least about the line just typed.
        __deathrace_command=$BASH_COMMAND
      fi
    }

    # DEBUG fires before every command, including each line of this file and everything any
    # PROMPT_COMMAND entry runs. Four things make it fire once, for the command you typed:
    #
    #   · it is disarmed at the start of the prompt and armed again at the very end, so nothing
    #     another PROMPT_COMMAND entry runs is taken for yours — pressing Enter on an empty
    #     line used to report `history -a` as a command, and with no entries of your own it
    #     reported one of ours;
    #   · our own functions are ignored by name, for the one firing that straddles that window;
    #   · READLINE_LINE means a key binding is running (fzf's Ctrl-R) and COMP_LINE a
    #     completion, both of which run commands at the prompt that you did not type;
    #   · a subshell's firings are not the parent's command.
    #
    # One thing bash simply does not offer: a line that is *entirely* a subshell group, like
    # `(cd /tmp && ls)`, fires no DEBUG trap at all — the parent sees no simple command and the
    # subshell does not inherit the trap unless `set -T` is on, which we will not turn on in
    # your shell. Such a line gets no record. `cmd; (…)` and `(…) && cmd` are unaffected.
    #
    # $_ is passed in and put back at the end, because the trap is a command like any other:
    # without that, `mkdir x && cd $_` would try to cd into the name of a function of ours.
    __deathrace_debug() {
      local last=$1
      case $BASH_COMMAND in __deathrace_*) return 0 ;; esac
      if [ -n "$__deathrace_at_prompt" ] && [ -z "${READLINE_LINE+set}" ] &&
        [ -z "${COMP_LINE+set}" ] && [ "${BASH_SUBSHELL:-0}" = 0 ]; then
        __deathrace_at_prompt=
        __deathrace_ran=1
        __deathrace_started=${EPOCHREALTIME-}
        __deathrace_typed
        __deathrace_escape "$__deathrace_command"
        printf '\e]633;E;%s\a\e]133;C\a' "$__deathrace_escaped"
      fi
      __deathrace_keep_underscore 0 "$last"
    }

    # Nothing but `return`, and that is the whole trick: $_ is the last argument of the last
    # command run, so being that command — with the old value as its last argument — is what
    # puts it back. Returning 0 as well, because a DEBUG trap that returns non-zero skips the
    # command it fired for when `extdebug` is on.
    __deathrace_keep_underscore() { return $1; }

    # Prepended to PROMPT_COMMAND, so that $? is still your command's. Appended, it was
    # whatever the entry before it returned — and with `history -a`, the commonest value there
    # is, every failing command reported success.
    __deathrace_status() {
      __deathrace_ended=$?
      __deathrace_at_prompt=
      return $__deathrace_ended
    }

    # Appended, so it has the last word on the prompt: a framework that builds PS1 from its own
    # PROMPT_COMMAND entry — Starship, powerline — runs before this and would otherwise throw
    # the B marker away on every prompt it drew.
    __deathrace_prompt() {
      if [ -n "$__deathrace_ran" ]; then
        local duration=
        if [ -n "$__deathrace_started" ] && [ -n "${EPOCHREALTIME-}" ]; then
          # Whole and fractional parts separately, in integer arithmetic, because bash has no
          # floats. The comma is a locale's decimal point: $EPOCHREALTIME follows LC_NUMERIC,
          # so left alone, `sleep 0.3` in a German locale reported dur=304037614. `10#` forces
          # base ten, or a fraction like 012345 would be read as octal — and 098765 would be a
          # syntax error.
          local from=${__deathrace_started/,/.} to=${EPOCHREALTIME/,/.}
          local ms=$(( (${to%.*} - ${from%.*}) * 1000 + (10#${to#*.} - 10#${from#*.}) / 1000 ))
          [ "$ms" -lt 0 ] && ms=0
          duration=";dur=$ms"
        fi
        printf '\e]133;D;%d%s\a' "$__deathrace_ended" "$duration"
      fi
      __deathrace_started=
      __deathrace_ran=
      # Re-applied here rather than once at load, for the same reason this runs last: a PS1
      # assigned after we were sourced — by a prompt framework, or by your rc being sourced
      # again — would otherwise have lost the marker for good. \[...\] tells bash the bytes
      # take no columns, without which every prompt would be mismeasured.
      case $PS1 in
        *133\;B*) ;;
        *) PS1="${PS1}\[\e]133;B\a\]" ;;
      esac
      printf '\e]133;A\a'
      __deathrace_at_prompt=1
      return $__deathrace_ended
    }
  fi

  trap '__deathrace_debug "$_"' DEBUG

  # PROMPT_COMMAND may be an array, from bash 5.1 on, and assigning a string to one replaces
  # only its first element. `declare -p` rather than ${PROMPT_COMMAND@a} to tell which it is:
  # bash 3.2 cannot parse the latter at all.
  if [[ $(declare -p PROMPT_COMMAND 2>/dev/null) == 'declare -a'* ]]; then
    __deathrace_found=
    for __deathrace_entry in "${PROMPT_COMMAND[@]}"; do
      case $__deathrace_entry in *__deathrace_prompt*) __deathrace_found=1 ;; esac
    done
    if [ -z "$__deathrace_found" ]; then
      PROMPT_COMMAND=(__deathrace_status "${PROMPT_COMMAND[@]}" __deathrace_prompt)
    fi
    unset __deathrace_found __deathrace_entry
  else
    case ${PROMPT_COMMAND-} in
      *__deathrace_prompt*) ;;
      '') PROMPT_COMMAND='__deathrace_status;__deathrace_prompt' ;;
      *) PROMPT_COMMAND="__deathrace_status;${PROMPT_COMMAND%;};__deathrace_prompt" ;;
    esac
  fi
fi
