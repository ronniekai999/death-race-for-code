# Death Race for Code — zsh, step one of the hand-off.
#
# ZDOTDIR points at this folder so our files get to run, which also means zsh looks for *your*
# startup files here and would skip them. So each of our files hands ZDOTDIR back to you,
# sources yours, and takes it again: you get the files zsh would have read, in the order it
# would have read them, and nothing of yours is written to.
#
# The two helpers below are defined here because zsh reads this file before any other, so
# .zprofile, .zshrc and .zlogin can all use them. Whichever of ours runs last removes them.

# Hand ZDOTDIR back to you. Unset, if you never had one — which is not the same as $HOME: the
# variable's absence is itself part of the environment your own files were written for.
__deathrace_yours() {
  if [[ -n ${DEATHRACE_USER_ZDOTDIR+set} ]]; then
    ZDOTDIR=${DEATHRACE_USER_ZDOTDIR}
  else
    unset ZDOTDIR
  fi
}

# Take it back for the next of our files, remembering wherever yours left it. That last part
# is what makes the XDG layout work: it puts `export ZDOTDIR=~/.config/zsh` in .zshenv, so
# assuming the value we started with would send the rest of the hand-off to the wrong folder,
# where it would find nothing of yours and quietly do nothing at all.
__deathrace_ours() {
  if [[ -n ${ZDOTDIR+set} ]]; then
    DEATHRACE_USER_ZDOTDIR=${ZDOTDIR}
  else
    unset DEATHRACE_USER_ZDOTDIR
  fi
  ZDOTDIR=${DEATHRACE_ZDOTDIR}
}

# And the last of the three, used by whichever of our files runs last.
__deathrace_done() {
  unset DEATHRACE_USER_ZDOTDIR DEATHRACE_ZDOTDIR
  unset -f __deathrace_yours __deathrace_ours __deathrace_done
}

DEATHRACE_ZDOTDIR=${ZDOTDIR}
__deathrace_yours
if [[ -r ${ZDOTDIR:-$HOME}/.zshenv ]]; then
  source "${ZDOTDIR:-$HOME}/.zshenv"
fi

__deathrace_ours

# A shell that is neither login nor interactive reads this file and no other, so the helpers
# have nobody left to help. ZDOTDIR stays ours, though, deliberately: handing it back here
# would take the integration away from every shell started under a `zsh -c` that happens to sit
# in a launch chain — silent, and far worse than the variable being visible to a script. Every
# zsh reads this file, so the hand-off happens again wherever it is actually needed.
if [[ ! -o login && ! -o interactive ]]; then
  unset -f __deathrace_yours __deathrace_ours __deathrace_done
fi
