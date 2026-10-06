# Death Race for Code — zsh, step one of the hand-off.
#
# ZDOTDIR points at this folder so that our .zshrc below gets to run, which means zsh looks
# for .zshenv here too and would otherwise skip yours. So run yours now, in the order zsh
# would have, and leave ZDOTDIR alone until .zshrc has had its turn.
#
# Nothing here is written to any file of yours. See docs/ARCHITECTURE.md.

if [[ -n ${DEATHRACE_USER_ZDOTDIR-} && -r ${DEATHRACE_USER_ZDOTDIR}/.zshenv ]]; then
  source "${DEATHRACE_USER_ZDOTDIR}/.zshenv"
fi
