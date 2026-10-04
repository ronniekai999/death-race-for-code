# Conformance

How we know `VTCore` behaves like a terminal. Every check runs on Linux in CI.

| Check | What it proves | Status |
| --- | --- | --- |
| Unit tests | each sequence and edge case we implement | parser, terminal, reflow, input, deltas, sessions |
| esctest | xterm-compatible behavior, through `vthost` answering its queries | 356 pass; ratchet in CI |
| vttest | the classic VT100/VT220 screens, driven through `vthost` against goldens | Phase 1 |
| libFuzzer | no crashes or hangs on arbitrary input; deltas replay to the same screen | Phase 1 |
| SwiftTerm differential | same input, same screen, with a reviewed list of known divergences | Phase 1 |
| Recorded corpus | vim, nvim, tmux, htop, btop, fzf, lazygit, CJK and emoji sessions end on golden screens | Phase 1 |

## esctest

`scripts/esctest.sh` fetches esctest2 at a pinned commit, runs it inside `vthost run
--checksums` (an 80×25 terminal that answers DECRQCRA), and compares the failing tests with
`Packages/DeathRaceKit/Tests/Fixtures/esctest-known-failures.txt`. We test against current
xterm: `--expected-terminal xterm --xterm-checksum 334 --xterm-reverse-wrap 383
--max-vt-level 5`.

| | Tests |
| --- | ---: |
| Pass | 356 |
| Marked by esctest as known xterm bugs | 40 |
| Fail: features scheduled for later | 156 |
| Fail: deliberate differences from xterm | 15 |

That is 356 of 371 (96%) on the v1 scope, counting the deliberate differences as failures.

**Scheduled for later** (from the plan's "Later" list): left/right margins, DECSLRM (66
tests); rectangle operations, DECCRA, DECERA, DECFRA, DECSERA (22); special colors, OSC
5/105/106 (19); window manipulation and title reports (19, and see below); CIE, TekHVC
and RGBi color specifications (14); DECIC, DECDC, DECBI, DECFI (11); ISO protected areas,
SPA/EPA (5).

**Deliberate differences:**

- **We say we are a VT220** (DA1 `?62;22c`, DA2 `>1;10;0c`, DECSCL 62). xterm claims VT420
  or VT525 features we do not have, and programs act on those claims (6 tests).
- **The window owns its size.** Programs cannot resize it (DECSLPP, DECSNLS, `CSI 8 t`) or
  switch it to 132 columns (DECCOLM) (5 tests).
- **Titles cannot be read back** (`CSI 20 t`, `CSI 21 t`). Title reports are a well-known
  way to type text into a shell (1 test).
- **DECSCL does not change the conformance level** (1 test), and **mode 41**, xterm's
  workaround for an old `more(1)` bug, is not implemented (1 test).
- **DECARM can be set and queried.** esctest expects xterm to fail this test, so passing it
  counts as a failure (1 test).

## Rules

- **esctest is a ratchet.** A known-failures list lives in the test fixtures. CI fails on a new
  failure and on an unexpected pass, so the list only ever shrinks on purpose. esctest is
  GPL-2.0, so CI fetches it rather than vendoring it.
- **xterm decides.** When `VTCore` and SwiftTerm disagree, xterm's behavior as esctest encodes
  it is the reference.
- **DECRQCRA stays in test mode.** esctest reads the screen through checksums, but a program
  that can checksum the screen can read it, so the app never answers DECRQCRA.
- **Bugs esctest found are fixed with a unit test**, so the engine's own suite keeps the
  behavior even where esctest cannot see it. The first full run found: DECSTR not resetting
  reverse wraparound, the cursor not carried across 47/1047 screen switches, CUB ignoring
  reverse wraparound, a missing mode 1045 and XTSAVE/XTRESTORE, DECXCPR's page number, and
  unanswered status reports.

## v1 scope

C0 and ESC (with the DEC line-drawing charset), CSI cursor/erase/insert/delete, scroll regions,
tabs, REP, DECALN, full SGR (truecolor, underline styles and color), alternate screen
1049/47/1047, mouse 1000/1002/1003/1006, focus 1004, bracketed paste 2004, synchronized output
2026, DECSCUSR, DA/DSR/CPR/DECRQM/DECRQSS/XTVERSION/XTGETTCAP/XTWINOPS 18t, OSC 0/2/4/7/10–12,
OSC 52 (write only), OSC 9;4, OSC 133, and the Kitty keyboard protocol.

Later: OSC 8 hyperlinks (Phase 3), Sixel, Kitty graphics, iTerm2 images, DECSLRM, double-width
lines, rectangle operations, VT52.
