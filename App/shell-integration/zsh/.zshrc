# Death Race for Code — zsh, step two: your files, then our hooks on top.
#
# What this reports, so a block knows where it starts and how it went:
#   OSC 133;A            a prompt starts here
#   OSC 133;B            the prompt ends and what you type begins (appended to PS1)
#   OSC 633;E;<command>  the command line, escaped as Visual Studio Code escapes it
#   OSC 133;C            the command's output starts here
#   OSC 133;D;<exit>;dur=<ms>
#
# The duration comes from here because the shell is the only thing that knows it: the
# terminal has no clock on this path at all, and a command that finished while the app was
# closed was never watched by anything that could have timed it.

# Put your ZDOTDIR back before anything else runs, so a zsh started from this one reads your
# files and not ours. Without this the variable is inherited for ever.
if [[ -n ${DEATHRACE_USER_ZDOTDIR-} ]]; then
  ZDOTDIR="${DEATHRACE_USER_ZDOTDIR}"
else
  unset ZDOTDIR
fi
unset DEATHRACE_USER_ZDOTDIR

# Yours first, and never after: a prompt framework replaces hooks wholesale when it loads, so
# anything we add before it would be thrown away.
if [[ -r ${ZDOTDIR:-$HOME}/.zshrc ]]; then
  source "${ZDOTDIR:-$HOME}/.zshrc"
fi

# From here on, if anything is missing we do nothing rather than break your shell.
if [[ -o interactive ]] && zmodload zsh/datetime 2>/dev/null; then

  typeset -g __deathrace_started=
  typeset -g __deathrace_ran=

  # `;` would end the parameter and `\` is the escape itself. The newline, carriage return
  # and tab are spelled out so a command written across two lines survives as one line of
  # text. Pure parameter expansion: no forks, because this runs on every command you type.
  __deathrace_escape() {
    local text=${1//\\/\\\\}
    text=${text//;/\\x3b}
    text=${text//$'\n'/\\x0a}
    text=${text//$'\r'/\\x0d}
    text=${text//$'\t'/\\x09}
    printf '%s' "$text"
  }

  __deathrace_precmd() {
    # Not `status`: zsh keeps that name read-only as another spelling of `?`, and assigning
    # to it fails on the first line, taking the whole hook with it.
    local ended=$?
    if [[ -n $__deathrace_ran ]]; then
      local duration=
      if [[ -n $__deathrace_started ]]; then
        # `-F` for fixed-point: a plain assignment can come back in scientific notation,
        # which the truncation below would read as nonsense. And truncation rather than
        # `int()`, which lives in zsh/mathfunc and is not loaded by default.
        local -F elapsed=$(( (EPOCHREALTIME - __deathrace_started) * 1000 ))
        (( elapsed < 0 )) && elapsed=0
        duration=";dur=${elapsed%%.*}"
      fi
      printf '\e]133;D;%d%s\a' "$ended" "$duration"
    fi
    __deathrace_started=
    __deathrace_ran=
    printf '\e]133;A\a'
  }

  __deathrace_preexec() {
    __deathrace_started=$EPOCHREALTIME
    __deathrace_ran=1
    printf '\e]633;E;%s\a' "$(__deathrace_escape "$1")"
    printf '\e]133;C\a'
  }

  # Appended, never assigned: assigning would drop Oh My Zsh's, Starship's and
  # Powerlevel10k's own hooks, which is the usual way an integration breaks a prompt.
  typeset -ga precmd_functions preexec_functions
  precmd_functions+=(__deathrace_precmd)
  preexec_functions+=(__deathrace_preexec)

  # B marks the end of the prompt, so it belongs in the prompt itself. %{...%} tells zsh the
  # bytes take no columns, without which every prompt would be mismeasured.
  if [[ $PS1 != *'133;B'* ]]; then
    PS1="${PS1}%{"$'\e]133;B\a'"%}"
  fi
fi
