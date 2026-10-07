# Conformance

How we know `VTCore` behaves like a terminal. Every check runs on Linux in CI.

| Check | What it proves | Status |
| --- | --- | --- |
| Unit tests | each sequence and edge case we implement | parser, terminal, reflow, input, deltas, sessions |
| esctest | xterm-compatible behavior, through `vthost` answering its queries | 358 pass; ratchet in CI |
| vttest | the classic VT100/VT220 screens, each checked against what vttest says it should show | 10 suites, 139 screens |
| libFuzzer | no crashes or hangs on arbitrary input; deltas replay to the same screen | 1 min per PR, 30 min weekly |
| SwiftTerm differential | every corpus screen through SwiftTerm too; each divergence reviewed | 165 screens, 5 differ, all SwiftTerm's |
| Recorded corpus | real programs' output replays to golden screens: text, cursor and styles, at every key press, whole and in pieces | 9 programs; btop and lazygit to come |
| Frame goldens | five of those recordings built into the frames the app draws: background, text and decoration colors with the default theme | htop, vim, tmux, less, vttest's colors |

## esctest

`scripts/esctest.sh` fetches esctest2 at a pinned commit, runs it inside `vthost run
--checksums` (an 80×25 terminal that answers DECRQCRA), and compares the failing tests with
`Packages/DeathRaceKit/Tests/Fixtures/esctest-known-failures.txt`. We test against current
xterm: `--expected-terminal xterm --xterm-checksum 334 --xterm-reverse-wrap 383
--max-vt-level 5 --options xtermWinopsEnabled`. Without the last option, esctest expects
xterm to fail the tests that need window operations and files our failures there as xterm's
known bugs; with it, our deliberate refusals count as failures and DECNCSM counts as a pass.

| | Tests |
| --- | ---: |
| Pass | 404 |
| Marked by esctest as known xterm bugs | 33 |
| Fail: features scheduled for later | 89 |
| Fail: refused by design, or a deliberate difference | 41 |

That is 404 of 445 (91%) of the tests for behavior we mean to have, counting the refusals as
the failures they are. The headline moved from "95% of 378" in the other direction than it
looks: the 19 window-manipulation tests used to be filed under "later", and they are never
going to pass, so they are counted here among the refusals instead.

**Scheduled for later:** colors — OSC 4/5/104/105/106 and the CIE, TekHVC and RGBi color
specifications (33 tests); rectangle operations, DECCRA, DECERA, DECFRA, DECSERA (24);
DECIC, DECDC, DECBI and DECFI (20); origin mode against a left margin (7); ISO protected
areas, SPA/EPA (5).

**Left and right margins (DECSLRM) are in**, which is what moved the number: 47 of those
tests passed with the margins themselves and the reports, and another 44 once movement,
scrolling, printing and the editing sequences were bounded by them.

**Refusals and deliberate differences:**

- **The window does not move, resize, raise or lower itself.** `Terminal+CSI.swift` answers
  XTWINOPS' reports and its title stack and ignores the rest: a program does not get to
  rearrange the desktop (19 tests). These are never going to pass, and that is the point.
- **We say we are a VT220** (DA1 `?62;22c`, DA2 `>1;10;0c`, DECSCL 62). xterm claims VT420
  or VT525 features we do not have, and programs act on those claims (5 tests).
- **The window owns its size.** Programs cannot resize it (DECSLPP, DECSNLS, `CSI 8 t`) or
  switch it to 132 columns (DECCOLM) (6 tests). Once a program allows the switch (mode
  40), DECCOLM still clears the screen (unless DECNCSM), resets the margins and homes the
  cursor, as xterm does when the window manager refuses the resize.
- **Titles cannot be read back** (`CSI 20 t`, `CSI 21 t`). Title reports are a well-known
  way to type text into a shell (5 tests).
- **The clipboard cannot be read** (OSC 52 with `?`): a program would see whatever the user
  last copied (1 test).
- **DECSCL does not change the conformance level** (3 tests). We answer DECRQSS `"p"` as a
  VT220 and offer every sequence we have whatever a program asks for, so a program that sets
  level 3 and then sets a left margin gets one, where xterm refuses it. Gating features by a
  conformance level would recover these three; nothing else needs it.
- **Mode 41**, xterm's workaround for an old `more(1)` bug, is not implemented (1 test).
- **DECARM can be set and queried.** esctest expects xterm to fail this test, so passing it
  counts as a failure (1 test).

## vttest

vttest draws a screen and says what it should look like ("a frame of E's around this text
with one free position", "the right column should be staggered by one"). It runs inside
`vthost run` like the corpus programs below, and every screen it draws, at every key press,
is a golden (`vttest-*` in the corpus). Each screen was checked against vttest's own words and
against vttest's source where the words leave room.

| Suite | Covers |
| --- | --- |
| vttest-cursor | cursor movement, autowrap with controls mixed in, controls inside sequences, leading zeros |
| vttest-screen | wrap-around, tab stops, reverse video, soft and jump scrolling in regions, origin mode, renditions, save/restore cursor |
| vttest-charsets | the VT100 character sets (British, DEC Special Graphics), SI/SO |
| vttest-reports | DSR, DA1, DA2, DA3 |
| vttest-insdel | the VT102 accordion, insert mode, ICH, DCH |
| vttest-wrap | wrap-around with cursor addressing |
| vttest-vt220 | VT220 status reports, DECTCEM, ECH, DECSCA with DECSED/DECSEL |
| vttest-iso6429 | HPA, CBT, CHA, CHT, HPR, VPA, CNL, CPL, VPR, REP, SD, SU |
| vttest-colors | the 8×8 color matrix, SGR 0, background color erase through ED, EL, ECH and scrolling, SGR 22–27 |
| vttest-altscreen | modes 47, 1047 and 1049 |

vttest runs as `vttest 24x80.80`: programs cannot switch the window to 132 columns here, so
its 132-column passes run at 80. Left out: double-size lines (DECDWL, DECDHL; vttest's
stagger test uses them, so its second pass shows single-width lines), VT52, 8-bit and national
character sets, the keyboard tests, and two reports vttest waits for and we do not send: the
ENQ answerback (empty, as in xterm) and DECREQTPARM (which xterm answers only as a VT100).

vttest found a bug esctest does not test: REP repeated after another REP. A control sequence,
REP included, now ends what REP can repeat, as xterm does.

## SwiftTerm differential

`make vtdiff` builds `Tools/VTDiff`, a package of its own that fetches SwiftTerm at a pinned
commit (v1.20.0), so SwiftTerm never comes near the app. It feeds every corpus recording to
both engines and compares every screen a golden holds, row by row, and the cursor. SwiftTerm
is a referee, not the reference: where they disagree, xterm decides, as esctest and vttest
encode it. The weekly workflow runs it too.

Of 165 screens, 5 differ, and in each SwiftTerm departs from xterm:

| Screen | VTCore | SwiftTerm | Who is right |
| --- | --- | --- | --- |
| vttest-charsets, DEC Special Graphics | `_` is a blank (U+00A0) | `_` | DEC's table: 0x5F is blank |
| vttest-cursor, autowrap (two screens) | the screen clears on DECCOLM under mode 40 | nothing clears | xterm, and vttest's layout |
| vttest-iso6429, REP | REP after REP repeats nothing | it repeats again (12 +'s) | vttest and xterm: 2 +'s |
| vttest-vt220, DECSCA | protected cells survive DECSED and DECSEL | erased | vttest: "a solid box" |

## Recorded corpus

`scripts/record-corpus.sh` runs real programs inside `vthost run --record`, at 80×24, typing
scripted keys once the screen settles: vim (plain and with syntax colors), nvim with a
vertical split, less searching, tmux with three panes, htop, fzf's inline mode, nano, a
file of CJK, emoji, flags and combining marks, and the vttest suites above. Each recording
sits in `Packages/DeathRaceKit/Tests/Fixtures/corpus/` with its marks (how much output came
before each key press) and its golden, the screens `vthost replay --marks` prints: at every
key press and at the end, every row's text, the cursor, screen-wide reverse video, and each
run of styled cells as SGR parameters. `CorpusTests` replays every recording whole, a byte
at a time and in random pieces, and each must match its golden exactly.

Five recordings (htop, vim with syntax colors, tmux, less searching and vttest's color
tests) also have frame goldens in `Tests/Fixtures/frames/`: `vthost frame --summary` replays
them through the app's own path (an in-process session, the mirror, the color rules and the
frame builder) and writes the runs of background, text and decoration colors the GPU would
draw, at every key press. `FrameGoldenTests` checks them, so a change in how colors resolve
(inverse, faint, bold, reverse video) shows up on real programs' screens.

Recordings depend on program versions, so they are recorded once and checked in. After a
deliberate engine change, `scripts/record-corpus.sh --goldens` rewrites the goldens from
the same recordings; the diff shows what changed on real screens and gets reviewed like code.
The recordings keep this machine out of them: tmux gets a plain prompt and a fixed status
line, and htop lists only itself. btop is left out for now because it shows the host name,
CPU model and every process; lazygit is not packaged for the Linux image.

## Fuzzing

`make fuzz` builds `Tools/VTFuzz` (a separate package, since libFuzzer supplies `main`) with
AddressSanitizer and runs it from a seed corpus of representative output. Each input picks a
terminal size, then interleaves output, resizes and scrolling. After every step the delta goes
through `DeltaCodec` into a `MirrorGrid`, which must equal a fresh snapshot. Inputs starting
with a zero byte go straight to the delta decoder, which must fail cleanly. Linux CI fuzzes
for a minute on every pull request; `nightly.yml` fuzzes for half an hour weekly and carries
the corpus forward. Xcode's toolchain has no libFuzzer runtime, so fuzzing runs on Linux (or
with the swift.org toolchain on a Mac).

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
left and right margins (DECLRMM and DECSLRM), tabs, REP, DECALN, full SGR (truecolor, underline styles and color), alternate screen
1049/47/1047, mouse 1000/1002/1003/1006, focus 1004, bracketed paste 2004, synchronized output
2026, DECSCUSR, DA/DSR/CPR/DECRQM/DECRQSS/XTVERSION/XTGETTCAP/XTWINOPS 18t, OSC 0/2/4/7/10–12,
OSC 52 (write only), OSC 9;4, OSC 133, OSC 633;E, and the Kitty keyboard protocol.

`OSC 133;D` takes a parameter walk rather than one value: the first bare number is the exit
code and the rest are `key=value`, which is how `dur=<ms>` rides along. Before Phase 8 only the
first parameter was read, and only as an `Int32`, so `D;aid=7` lost the exit code and a bare `D`
cleared one already on the row. `OSC 633;E;<command>` is VS Code's, with its backslash
unescaping (`\\` for a backslash, `\xHH` for `;` and any control character), so our scripts
light up in its terminal and its scripts light up in ours. Neither is ours to define, and `dur=`
is parameter-shaped so every other terminal ignores it.

Later: Sixel, Kitty graphics, iTerm2 images, double-width lines, rectangle operations, VT52.
