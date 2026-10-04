# Manual tests

What CI cannot check, because it needs a real Mac, a real GPU, a keyboard, input methods and
your eyes. Run it with a debug build (`CONFIG=debug make run`) before closing a phase, and
note the macOS build (`sw_vers`) with the results.

## Phase 2 exit criteria

Phase 2 is done when all of these hold on the M5:

1. zsh, vim, htop and tmux render correctly (the sections below).
2. An idle window draws no frames: **Debug › Log Frame Stats** shows the frame count
   standing still while nothing changes, and the cursor keeps blinking.
3. The budgets in [PERF.md](PERF.md) are met.
4. The [legendsd spike](SPIKE.md)'s verdict is in [ARCHITECTURE.md](ARCHITECTURE.md#the-legendsd-spike).
5. `make test-render` passes, with its goldens committed.

## Rendering

- [ ] **zsh**
  - [ ] The prompt and typing look right.
  - [ ] Long lines wrap, and rewrap when the window is resized.
  - [ ] `ls -G` colors.
  - [ ] Emoji (`echo 🎉👩‍👩‍👧`) and CJK (`echo 你好 日本語`) take two cells and line up.
- [ ] **vim**
  - [ ] Syntax colors, and line numbers with `:set nu`.
  - [ ] The cursor is a bar in insert mode and a block in normal mode.
  - [ ] `:set mouse=a`: clicking moves the cursor and the wheel scrolls.
- [ ] **htop**
  - [ ] The colored meters, the header bar and the F-key labels.
  - [ ] Clicking a column header sorts by it.
- [ ] **tmux**
  - [ ] Pane borders join, with no gaps between rows.
  - [ ] With `set -g mouse on`, clicking selects a pane and dragging a border resizes it.
- [ ] **less**: a search (`/word`) highlights its matches.
- [ ] **Retina and non-Retina**: drag the window to an external display. Text stays sharp
      and the grid is laid out again.

## Keyboard

- [ ] Left Option is Meta: Option-B and Option-F move by words in zsh. Right Option types
      special characters (Option-2 is ™ on a US layout). The `option-as-meta` setting
      changes this.
- [ ] **Dead keys** (US layout): Option-E then E types é.
- [ ] **Japanese**: with Kotoeri or another Japanese input method, type `nihongo`.
  - [ ] The composing text appears at the cursor, underlined.
  - [ ] The candidate window opens under it.
  - [ ] Return commits.
- [ ] **Korean** (2-Set): type a syllable, then press Return once. The syllable and the
      Return both arrive.
- [ ] **US-International**: `'` then Return types `'` and runs the line, in one press.
- [ ] **Russian layout**: Control-C interrupts `sleep 10`, and Control-D ends `cat`.
- [ ] An unbound ⌘ chord (⌘J) beeps and types nothing.
- [ ] **Emoji & Symbols** (Control-Command-Space): the chosen emoji is typed.
- [ ] Holding a key repeats it; no accent popup appears.
- [ ] ⌘1–⌘9 switch tabs; ⌘⇧[ and ⌘⇧] go to the previous and next tab.
- [ ] Kitty keyboard protocol: in a program that enables it (`kitten show-key -m kitty`),
      key releases and modifier keys are reported.

## Mouse, selection, clipboard

- [ ] Selecting:
  - [ ] Dragging selects characters.
  - [ ] A double click selects a word, a whole path or URL included.
  - [ ] A triple click selects the whole line, across soft wraps.
  - [ ] Option-drag selects a rectangle; Shift-click extends a selection.
  - [ ] Dragging past the top edge scrolls into history.
- [ ] ⌘C copies:
  - [ ] a selection on screen;
  - [ ] a selection that reaches into history;
  - [ ] after ⌘A, the whole history.
- [ ] Output arriving does not move a selection off its text; typing clears it.
- [ ] Paste warnings:
  - [ ] In `cat`, which does not ask for bracketed paste, pasting three lines asks
        "Paste 3 lines?" and shows them.
  - [ ] In zsh, which does ask, it pastes without asking.
  - [ ] `paste-protection = false` turns the question off.
- [ ] Dropping files from Finder types their paths, quoted (try a name with spaces).
- [ ] **OSC 52**:
  - [ ] In tmux with `set -g set-clipboard on`, copy-mode yank reaches the macOS clipboard.
  - [ ] With `clipboard-write = ask` it asks first.
  - [ ] With `deny` nothing is copied.
- [ ] The wheel and trackpad:
  - [ ] They scroll history, with momentum.
  - [ ] In `less` and `man`, they scroll the program.

## Windows, tabs, settings

- [ ] ⌘T opens a tab in the current directory, after a `cd` in zsh. (macOS's zsh does not
      report directories, so this checks the foreground-process path.)
- [ ] Closing a tab running `vim` asks "Goodbye & Good Riddance?"; closing one at the
      prompt does not. ⌘Q with `vim` running asks once.
- [ ] `exit` closes the tab; `exit 3` leaves it open with "The shell exited with status 3."
- [ ] ⌘+, ⌘− and ⌘0 change this window's font size; the grid keeps the window size.
- [ ] Settings… opens the config file. After an edit, Reload Configuration (⌘⇧,) applies
      it to open windows:
  - [ ] font size, padding and cursor style;
  - [ ] `background` and `palette`. A program's own colors (`printf '\e]11;#203040\a'`)
        stay.
- [ ] A misspelled setting (`font-szie = 14`) is reported with a suggestion.
- [ ] The bell (`printf '\a'`):
  - [ ] `bell = system` beeps; `visual` flashes; `none` stays silent.
  - [ ] In the background, the Dock icon bounces once.
- [ ] The cursor:
  - [ ] It blinks for 30 seconds after the last key press, then stays solid.
  - [ ] Unfocused, it is a hollow block that does not blink.

## Secure Keyboard Entry

- [ ] Run `sudo -k; sudo true`. At the password prompt:
  - [ ] a lock shows in the title bar;
  - [ ] `ioreg -l -w 0 | grep -i SecureInput` in another app's terminal shows Death Race's pid.
- [ ] After the prompt, the lock goes away.
- [ ] Death Race › Secure Keyboard Entry keeps it on while the app is active; switching to
      another app turns it off.

## Energy and speed

See [PERF.md](PERF.md#measuring-on-the-mac) for the commands.

- [ ] Idle wakeups, 60 s with one idle window and the cursor blinking: at most 0.5/s.
- [ ] Hidden tabs and minimized windows draw nothing, even while their programs print.
- [ ] Key to screen p95, from Log Frame Stats after a minute of typing in vim: at most
      one refresh plus 3 ms.
- [ ] Memory with 1 and with 11 idle tabs (`footprint`): at most 50 MB per tab.
- [ ] Instruments, Animation Hitches template: no hitches while scrolling `htop` or `cat`
      on a large file.
