# Death Race for Code — zsh, the last login step.
#
# Only a login shell that is *not* interactive reaches this file: in an interactive one .zshrc
# has already handed ZDOTDIR back for good, so zsh finds your own .zlogin instead of ours. It
# is here so that `zsh -lc …` — a login shell with no prompt — still reads everything of yours.

__deathrace_yours
if [[ -r ${ZDOTDIR:-$HOME}/.zlogin ]]; then
  source "${ZDOTDIR:-$HOME}/.zlogin"
fi
__deathrace_done
