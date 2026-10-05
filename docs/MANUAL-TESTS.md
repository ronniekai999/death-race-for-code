# Manual tests

What CI cannot check, because it needs a real Mac, a real GPU, a keyboard, input methods and
your eyes. Run it with a debug build (`CONFIG=debug make run`) before closing a phase, and
note the macOS build (`sw_vers`) with the results.

Phase 6's checks come first; Phase 5's, Phase 4's, Phase 3's and Phase 2's follow, and still
apply.

## Phase 6 exit criteria

Phase 6 is done when all of these hold on the M5, against a real host:

1. **Round trip.** Open in Maze on a connected host, upload a file, then download it back
   under another name, and `shasum` the two: the bytes match. A few megabytes, so the bar has
   something to show.
2. **No second login.** Opening Maze on a host that already has a pane does not ask for Touch
   ID or a password, and no new `ssh` login appears in the host's auth log — the subsystem
   rides the master (`ps` shows one `ssh -M` for the host, plus the `-s sftp` child).
3. **Both sides browse.** Double-click steps into folders on either side, Up walks back, `/`
   disables Up, and folders sort before files.
4. **Drags.** A file dragged from Finder onto the host's pane uploads; a file dragged between
   the panes transfers that way; a folder dropped on the host's pane says "Maze moves files,
   not folders." and moves nothing.
5. **Replace asks.** Uploading or downloading onto a name that is already there asks first;
   Cancel leaves both sides as they were and starts no transfer.
6. **Stop works.** Stop on a transfer in flight ends it; the row reads cancelled and Clear
   takes it away. A part-written file on the far side is the documented cost of stopping an
   upload.
7. **Zero when idle.** With a Maze window open and no transfer running, the app draws no
   frames and costs ≈0 CPU (`powermetrics`); the reader thread sits in `read`.
8. **Closing cleans up.** Closing the window ends the subsystem (no `sftp` process left) and,
   once no pane is on the host either, the master idles out on its own.
9. **It looks right.** The window matches the Maze board in all 8 themes, light Righteous
   included, and the transfer bars run in the theme's gradient.

## Maze

- [ ] Opening Maze on a host that has no connection yet connects first (Touch ID once), then
      lists both sides.
- [ ] A host that refuses the subsystem (`Subsystem sftp` missing from its sshd) says so
      rather than hanging.
- [ ] Opening Maze on a second host gives a second window, cascaded, each on its own host.
- [ ] Open in Maze appears in the Shell menu, Hear Me Calling, and the host's context menu in
      the sidebar and the WRLD window — and is off in a local-shell pane.
- [ ] Changing the theme re-colours an open Maze window at once.
- [ ] Quitting with a Maze window open leaves no `ssh` or `sftp` process behind.

## Phase 5 exit criteria

Phase 5 is done when all of these hold on the M5:

1. **It drops in fast.** ⌥Space springs Lucid Dreams out of the notch in under 100 ms, and the
   same key or Esc hides it. Summoning it does not switch away from the app in front.
2. **The session persists.** Hiding and showing keeps the same shell, its scrollback and its
   working directory; only quitting ends it.
3. **Zero while hidden.** With the panel hidden, the app draws no frames and the quick terminal
   costs ≈0 CPU (`powermetrics`); it wakes only when its shell has output.
4. **It lands under the notch.** It opens on the screen under the pointer and centres under the
   notch; on a display without a notch it sits top-centre, fully on screen, on every display.
5. **The hotkey is yours.** `lucid-dreams-hotkey` in the settings file changes it and takes
   effect on save; `none` turns it off. The menu-bar moon and the View menu still open it.
6. **MenuGlance yields the notch.** With the snippet from
   [MENUGLANCE-HANDSHAKE.md](MENUGLANCE-HANDSHAKE.md) applied, MenuGlance's island hides while
   the panel is open and returns when it closes.
7. **Secure input is as documented.** The lock does not show on the quick terminal until you
   click into the app; once you do, it behaves as everywhere else.

## Lucid Dreams

- [ ] **⌥Space** opens and hides the panel; **Esc** hides it; a click on another app or window
      hides it.
- [ ] **The pane survives** hide and show (type something, hide, show — it is still there);
      quitting is the only thing that ends it.
- [ ] **On a notchless display** (or an external monitor) it sits top-centre and fully on
      screen; moving the pointer to another display and summoning opens it there.
- [ ] **The menu-bar moon** and **View › Lucid Dreams** both toggle it — the moon must *hide* an
      open panel, not merely re-show it, and opening a menu while the panel is up must not
      dismiss it on its own. The menu item shows a check while it is open.
- [ ] **`lucid-dreams-hotkey`** set to another shortcut (say `⌃⌘T`) re-registers on save;
      `none` turns the hotkey off while the menu and moon still work.
- [ ] **A busy program** (say `top`) keeps running while the panel is hidden, and its output is
      there when you show it again.

## Phase 5 energy

- [ ] Panel hidden, shell idle: 0 frames, and the app's share of wakeups at most 0.5 a second
      (`powermetrics`).
- [ ] Toggling it a few times leaves no timer running: once at rest, Log Frame Stats shows no
      frames.

## Phase 4 exit criteria

Phase 4 is done when all of these hold on the M5:

1. **A Secure Enclave key.** New Host… with "A new Secure Enclave key": Touch ID asks while
   it's made, the first connection signs in as usual and puts the key on the server, and from
   then on Touch ID asks once per connection. A split on that host (⌘D) opens with no second
   Touch ID.
2. **A tunnel, live.** Turning on 5432 → db:5432 in Come & Go works at once, with no new
   login; turning it off refuses new connections (ones already through run on); the status
   bar's "⇄ N tunnels" follows both.
3. **A saved password.** Saved from the password sheet, it connects after Touch ID next time.
   Declining Touch ID makes one attempt only, and the pane says the connection was cancelled.
4. **Your ~/.ssh/config.** Its hosts show up ("Found N hosts in ~/.ssh/config"), connect with
   their own settings, ProxyJump included, and the file's checksum (`shasum ~/.ssh/config`)
   doesn't change.
5. **The boards.** The sidebar, the WRLD window, Come & Go, Wishing Well and Armed and
   Dangerous match the mockup boards in all eight themes (CI's `chrome-preview` pictures,
   `<theme>.png` and `<theme>-armed.png`, are a start).
6. **Armed and Dangerous.** Armed panes each get typing in their own mode (↑ in vim and in
   zsh), ⇧⌘I stops it, and Esc reaches the programs.
7. **Energy.** Idle with the sidebar showing, two connections and a tunnel: 0 frames and at
   most 0.5 wakeups a second. With the sidebar and WRLD window hidden, no latency checks run.
8. **Local Network.** The first connection to a host on your network shows macOS's alert
   naming Death Race. If you deny it, the pane says how to allow it (Allow Local Network
   Access…).
9. **Quitting** with tunnels open asks first, and afterwards no `ssh -M` process remains
   (`pgrep -fl 'ssh .*-M'`).

The macOS side of Phase 4 was written while macOS CI could not run (see PR #4): expect the
first macOS build to need compile fixes before any of this can be tried.

## Connections

- [ ] **A WRLD host** (New Host…): connecting shows "Connecting to prod-api…" with Cancel,
      then the session; the pill and header say "prod-api".
- [ ] **A host from ~/.ssh/config** in Hear Me Calling (⇧⌘P, type its name): ↵ opens it in a
      new tab, ⌘↵ beside the active pane.
- [ ] **A second pane** on the same host opens at once, with no login.
- [ ] **Password prompts** come as sheets on the window; Save in the Keychain saves only after
      the login succeeds.
- [ ] **A new host key** shows its fingerprint in a sheet; Trust connects.
- [ ] **A changed host key** (edit its line in `~/.ssh/known_hosts`): the pane refuses, offers
      Forget the Old Key…, and the question shows both fingerprints. Forgetting reconnects,
      and ssh asks about the new key.
- [ ] **A failure** ("refused", "didn't answer", "no route") reads as a sentence, with
      Reconnect and Try Plain ssh.
- [ ] **Close and quit** name sessions on hosts ("prod-api's session") and open tunnels.

## Secure Enclave

- [ ] New Host… with "A new Secure Enclave key" makes it (Touch ID asks; macOS calls it
      "ctccardtoken"), and WRLD › Keys lists it with Copy Public Key.
- [ ] The first connection puts it in the server's `~/.ssh/authorized_keys` once, and the host
      switches to it; reconnecting asks Touch ID, not the password.

## WRLD window and sidebar

- [ ] **⌘O** opens WRLD: All hosts, Legends and groups with counts; host cards with chips and
      status; the selected card wears the NeonBorder.
- [ ] **The inspector** saves address, user, port, sign-in and jump host with Save; group,
      tags, Legend, agent forwarding and on-connect apply at once. A jump host can't be the
      host itself or loop back to it.
- [ ] **Remove…** names the hosts that jump through it; they connect directly afterwards.
- [ ] **Known hosts** lists `~/.ssh/known_hosts`; Forget… asks first.
- [ ] **⌃⌘S** and the button after the traffic lights show and hide the sidebar per window; a
      new window opens as the last was left. The status bar sits beside it.
- [ ] **Sidebar rows:** a click opens a host in a new tab, ⌘-click beside; a group opens and
      closes; right-click offers Connect, Connect Beside, Edit, Pin to Legends, Copy Address,
      Remove from WRLD….
- [ ] **Hand edits** to `wrld.json` and to `~/.ssh/config` show up as they're saved.
- [ ] **VoiceOver** reads each sidebar row, and presses it.

## Come & Go

- [ ] The add form (Local, Remote, Dynamic; Listen on; Forward to; Through) refuses a bad port
      and a port another tunnel listens on, in words.
- [ ] A tunnel set to open with its host opens when a pane on it connects.
- [ ] Hear Me Calling finds tunnels by port; ↵ turns one on or off.

## Wishing Well

- [ ] In Hear Me Calling, ↵ on a snippet types it without Return, ⌘↵ runs it; one with
      `{{fields}}` asks for them first, showing the command they make.
- [ ] A host's on-connect snippet (`tmux new -A -s main`) runs as each session on it starts.
- [ ] Edit › Save Selection to Wishing Well… (and the context menu) names the snippet for its
      first line; a Go template (`{{.State}}`) stays as it was.

## Armed and Dangerous

- [ ] ⇧⌘I in a tab of three panes: the banner over the panes, orange-to-pink borders, the pill
      "prod-api × 3", the status bar "Armed and Dangerous · 3 panes".
- [ ] Typing goes to every armed pane, each in its own mode; a header's "receiving input"
      leaves a pane out; Stop and ⇧⌘I disarm; Esc stays with the programs.
- [ ] A multi-line paste asks once, saying how many panes would run it line by line.
- [ ] A snippet while armed says "Run in 3 panes" and goes to all three.

## Phase 4 energy

- [ ] Idle with the sidebar, two connections and a tunnel: 0 frames, at most 0.5 wakeups a
      second (`powermetrics`).
- [ ] With the sidebar showing, one wakeup about every five minutes for latency checks; none
      with it and the WRLD window hidden (the debug log line PERF.md names stops).

## Phase 3 exit criteria

Phase 3 is done when all of these hold on the M5:

1. The window matches the mockup boards (Main, Themes, Settings, Hear Me Calling, App icon) in
   all eight themes, side by side. CI's `chrome-preview` artifact has a picture of each to
   start from; the traffic lights and the glow's blur are the window server's and only show
   on the Mac.
2. Idle with all the chrome showing, four panes and a background tab: 0 frames and at most
   0.5 wakeups a second.
3. Phase 2's budgets in [PERF.md](PERF.md) still hold with four panes in one tab.
4. Every theme passes the contrast tests (Linux CI checks this on every push).

## The window

- [ ] **Each of the eight themes** (Settings › Appearance, or Hear Me Calling): the title row,
      pills, cards, NeonBorder, status bar and terminal colors follow it.
  - [ ] Righteous makes the whole window light: menus, sheets and the traffic lights too.
  - [ ] Stars on the ground in the dark themes, and faint ones in the empty ends of rows
        (`starfield = true`); none in Righteous.
- [ ] **The traffic lights** sit in the middle of the 46 pt title row, and stay there after
      resizing, full screen and back, and moving to another display.
- [ ] **Tabs:**
  - [ ] Clicking a pill shows its tab; the × closes it; a middle click closes it.
  - [ ] Dragging a pill reorders the tabs.
  - [ ] Window › Move Tab to New Window, and the pill's context menu, move a tab with its
        panes running.
  - [ ] A background tab running `yes | head -c 50000000 > /dev/null; seq 1 2000000` shows
        the equalizer, which stops a moment after the output does. With Reduce Motion it
        stands still.
  - [ ] `printf '\a'` in a background tab puts a dot on its pill until it is shown.
  - [ ] `exit 3` leaves a red dot on the pill and Restart in the pane.
- [ ] **Closing:** ⌘W closes the pane, then the tab, then the window; ⌥⌘W the tab; ⇧⌘W and
      the red button the window. With `vim` running each asks once, naming it.

## Panes

- [ ] Four panes (⌘D, ⇧⌘D) running vim, htop, tmux and zsh, all drawing correctly.
- [ ] The pane in use has the NeonBorder, glowing in the key window; the others are dimmed,
      their cursors too.
- [ ] Headers show the program, folder, branch and the ⌥⌘ number; ⌥⌘1–4 focus them.
- [ ] ⌘⌥ arrows move between panes; ⌘[ and ⌘] step through them.
- [ ] Dragging a divider resizes the panes, which stop at 10 columns × 3 rows; a double click
      on it, or ⌃⌘=, evens them out.
- [ ] ⇧⌘↩ zooms the pane in use to the whole tab and back.

## Hear Me Calling

- [ ] ⇧⌘P, or the title bar's button, dims the window and opens the palette with the keys
      in its field.
- [ ] Typing finds actions (with their shortcuts), panes in every window, themes and
      Settings pages; matched letters are bold.
- [ ] ↑↓ move, ⇥ and ⇧⇥ narrow to one kind, ↵ chooses, esc closes; so does a click outside.
- [ ] Moving through themes shows each on this window; esc puts the old one back; ↵ saves it
      and every window follows.
- [ ] A pick comes first the next time, with nothing typed.

## Settings and live reload

- [ ] Settings… (⌘,) opens the window in the theme's colors, on Appearance.
- [ ] Each control changes its one line of the file (watch it in an editor) and applies at
      once: a theme swatch, the font, the size slider (written when the drag ends), a switch.
- [ ] An edit saved in an editor (vim, which saves by rename, and TextEdit) shows in the
      window and applies to every window within a moment.
- [ ] `font-size = huge` saved in an editor puts "1 setting could not be used" in the status
      bar; clicking it shows why, with a button to open the file.
- [ ] With the settings file a symlink into another folder, saving from Settings keeps the
      link and writes the file it points to.
- [ ] The Energy page shows CPU, wakeups and frames while it is open, and its numbers settle
      near zero with the terminal idle.

## Fonts and icons

- [ ] A Starship or Powerlevel10k prompt shows its icons with SF Mono and with the bundled
      Monaspace Neon, no patched font installed.
- [ ] `font-family = Monaspace Neon` with `font-family-italic = Monaspace Radon`:
      `printf '\e[3mitalic\e[0m'` draws in Radon.
- [ ] About credits the bundled fonts.
- [ ] The Dock, Finder and ⌘⇥ show icon B with no gray plate around it.

## Links

- [ ] `ls --hyperlink=auto` (GNU ls, `brew install coreutils` as `gls`): with ⌘ held over a
      name, its cells are underlined, the pointer is a hand and the status bar shows the
      `file://` address; ⌘-click shows the file in Finder and never opens it.
- [ ] `echo https://example.com/a-long-path-that-wraps…` in a narrow pane: ⌘-hover
      underlines the whole URL across the wrap; ⌘-click opens it in the browser.
- [ ] `printf '\e]8;;ssh://example.com\e\\ssh\e]8;;\e\\\n'`: ⌘-click asks first, naming
      the app.
- [ ] `printf '\e]8;;https://example.org\e\\https://apple.com\e]8;;\e\\\n'`: ⌘-click asks,
      since the text names another site.
- [ ] A right-click on a link offers Open Link and Copy Link.
- [ ] In vim with `:set mouse=a`, a ⌘-click on a URL follows it and vim sees no click.

## Phase 3 energy

See [PERF.md](PERF.md#measuring-on-the-mac) for the commands.

- [ ] Idle with all the chrome, four panes and a background tab: 0 frames, at most 0.5
      wakeups a second.
- [ ] `cat` of a large file draws at most 60 frames a second (signposts), and typing during
      it at the display's rate.
- [ ] In Low Power Mode, busy output draws at most 30 frames a second.
- [ ] Key to screen p95 with four panes is no worse than with one.
- [ ] `footprint` with four panes, against Phase 2's per-tab numbers.

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
- [ ] Open Settings File opens the config file. After an edit, Reload Configuration (⌘⇧,)
      applies it to open windows:
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
