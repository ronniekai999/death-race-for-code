# Conformance

How we know `VTCore` behaves like a terminal. Every check runs on Linux in CI.

| Check | What it proves | Status |
| --- | --- | --- |
| Unit tests | each sequence and edge case we implement | UTF-8 decoder done |
| esctest | xterm-compatible behavior, through `vthost` answering its queries | Phase 1 |
| vttest | the classic VT100/VT220 screens, driven through `vthost` against goldens | Phase 1 |
| libFuzzer | no crashes or hangs on arbitrary input; deltas replay to the same screen | Phase 1 |
| SwiftTerm differential | same input, same screen, with a reviewed list of known divergences | Phase 1 |
| Recorded corpus | vim, nvim, tmux, htop, btop, fzf, lazygit, CJK and emoji sessions end on golden screens | Phase 1 |

## Rules

- **esctest is a ratchet.** A known-failures list lives in the test fixtures. CI fails on a new
  failure and on an unexpected pass, so the list only ever shrinks on purpose. esctest is
  GPL-2.0, so CI fetches it rather than vendoring it.
- **xterm decides.** When `VTCore` and SwiftTerm disagree, xterm's behavior as esctest encodes
  it is the reference.
- **DECRQCRA stays in test mode.** esctest reads the screen through checksums, but a program
  that can checksum the screen can read it, so the app never answers DECRQCRA.

## v1 scope

C0 and ESC (with the DEC line-drawing charset), CSI cursor/erase/insert/delete, scroll regions,
tabs, REP, DECALN, full SGR (truecolor, underline styles and color), alternate screen
1049/47/1047, mouse 1000/1002/1003/1006, focus 1004, bracketed paste 2004, synchronized output
2026, DECSCUSR, DA/DSR/CPR/DECRQM/DECRQSS/XTVERSION/XTGETTCAP/XTWINOPS 18t, OSC 0/2/4/7/10–12,
OSC 52 (write only), OSC 9;4, OSC 133, and the Kitty keyboard protocol.

Later: OSC 8 hyperlinks (Phase 3), Sixel, Kitty graphics, iTerm2 images, DECSLRM, double-width
lines, rectangle operations, VT52.
