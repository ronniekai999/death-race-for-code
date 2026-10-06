# Death Race for Code — zsh, the login step.
#
# zsh reads .zprofile between .zshenv and .zshrc, and the app starts a login shell, so without
# this file yours is never read: ZDOTDIR is ours at that moment, and ours holds no .zprofile of
# yours. Homebrew's own instructions put `eval "$(brew shellenv)"` there, so missing it takes
# brew — and everything it adds to PATH — out of every pane.

__deathrace_yours
if [[ -r ${ZDOTDIR:-$HOME}/.zprofile ]]; then
  source "${ZDOTDIR:-$HOME}/.zprofile"
fi
# .zshrc is still to come, and zsh looks for it in ZDOTDIR.
__deathrace_ours
