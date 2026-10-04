# Architecture

Death Race for Code is a native macOS terminal with its own terminal engine, its own Metal
renderer, a Termius-style SSH layer built on the system's OpenSSH, and a session daemon that
keeps shells alive when the app quits. This file records the decisions and the reasons for
them. Read it before changing anything that moves bytes between the shell and the screen.

## The shape

```
 DeathRace.app (UI process)                           legendsd (Phase 7, LaunchAgent)
 ┌────────────────────────────────────────────┐       ┌───────────────────────────────┐
 │ DeathRaceApp  AppKit shell: WRLD sidebar,  │       │ SessionHost over XPC          │
 │   tabs, splits, Hear Me Calling, settings, │       │  owns PTYs + VTCore engines   │
 │   LucidDreams panel                        │       │  survives quit/crash/update   │
 │ TerminalUI  NSView: keys/IME/mouse/select  │◀─────▶│  same ScreenDelta bytes       │
 │ RenderKit   Metal: atlas, cells, cursor    │       └───────────────────────────────┘
 │ LegendsUI   tokens + Neon components       │
 │ MirrorGrid  screen copy the renderer draws │
 ├────────────────────────────────────────────┤
 │ SurfaceCore  geometry · colors · frames    │  ◀─ portable: the view's logic, Linux-tested
 │ ConfigKit   the settings file              │  ◀─ portable
 │ SessionKit  session thread: PTY + engine   │  ◀─ portable; moves into legendsd in Phase 7
 │ ScreenProtocol  ScreenDelta · DeltaCodec   │  ◀─ portable
 │ VTCore      parser · grid · scrollback     │  ◀─ portable, fuzzed, Linux-tested
 │ PTYKit      C spawn · termios · kqueue     │  ◀─ portable (Darwin + glibc)
 │ Vault · SSHKit · SFTPKit (Termius layer)   │  ◀─ SFTPKit portable
 └────────────────────────────────────────────┘
        │ spawns
        ▼
 /usr/bin/ssh (ControlMaster) · sftp subsystem · /usr/lib/ssh-keychain.dylib (Secure Enclave)
```

Everything below the line is portable Swift (plus one small C target). It builds and tests on
Linux, so the engine is developed test-first in a container with no Mac in the loop. Only the
UI half needs macOS.

## Modules today

| Target | Platform | Role |
| --- | --- | --- |
| `CPTY` | macOS, Linux | `openpty` → `fork` → `setsid` → `TIOCSCTTY` → `dup2` → `execve`, in C |
| `PTYKit` | macOS, Linux | `PseudoTerminal` (non-blocking master, resize, password-prompt detection, child-exit watch, hang-up), `ShellLaunch`, `SmokeTest` |
| `VTCore` | macOS, Linux | the engine: parser, screens and scrollback, reflow, SGR, modes, reports, OSC/DCS (OSC 8 links in per-row tables); key, mouse, focus and paste encoding |
| `ScreenProtocol` | macOS, Linux | `ScreenDelta`, `DeltaBuilder` (session side), `MirrorGrid` (app side), `DeltaCodec` (bytes for XPC, format 3) |
| `SessionKit` | macOS, Linux | `Session`: one thread per shell owning its PTY and engine, a locked mailbox for deltas and commands |
| `ConfigKit` | macOS, Linux | the settings file: `ConfigSchema` (one table drives the parser, the defaults and the template), `ConfigParser` with diagnostics, `Config`, `Theme`; `ThemeCatalog` (the eight themes, terminal and chrome) with `Contrast`; `ConfigEditor` (changes one setting, every other line as it was) |
| `Vault` | macOS, Linux | WRLD's data: `Vault` (hosts, groups, snippets, keys, tunnels) and `VaultStore` (`wrld.json`), `VaultEdits` (changes that keep references whole), `HostDraft`, `SnippetTemplate`, `TunnelSpec`, `WRLDState` (`state.json`: last connected, OS, latency, uses), `AtomicFile` |
| `SSHKit` | macOS, Linux | OpenSSH, driven: `GeneratedConfig`, `MasterSupervisor`/`MasterPool`/`MasterLog`, `AskpassBroker` and its wire format, `TunnelController`/`TunnelBoard`, `HostChain`, `LoginEnvironment`, `SecureEnclaveKeys`/`AuthorizedKeys`, `KnownHosts`, `HostChecks` (latency and OS, and when they may run), `PaneBanner`, `SSHConfigDiscovery`, `LocalNetwork`, `ProcessRunner` |
| `deathrace-askpass` | macOS, Linux | the `SSH_ASKPASS` helper: asks the app's broker, prints the answer |
| `AppCore` | macOS, Linux | the app's logic apart from AppKit: `SplitTree`, `WindowModel` (with the armed state), `ActionCatalog` (menus, palette, Keys page), `FuzzyMatcher`, `PaletteSearch`/`PaletteState`, `SettingsCatalog`, `EnergyMeter`, `GitHead`, `ShellLaunchPlan`, `StatusLine`/`TabLabel`, `BroadcastLabel`, `WishingWell`/`SnippetFill`, `WRLDBoard`, `SidebarModel`, `HostStatus`/`HostChips`/`RelativeTime` |
| `SurfaceCore` | macOS, Linux | what the terminal view does apart from AppKit and Metal: `SurfaceSession` (a `Session`, or `ReplaySession` in process), `SurfaceModel` (the mirror and what changed), `ColorResolver`, `FrameBuilder` (GPU instances, rebuilt per changed row), `SpriteRasterizer` (box drawing), `ShelfAtlas`, `CellMetrics`/`GridLayout`/`CellGeometry`, `Selection`/`WordRules`, `KeyRouting`/`MacKeyCode`, `ScrollAccumulator`, `FramePacer`, `FrameRatePolicy`, `SecureInput`, `PreeditLayout`, `ShellQuoting`, `WorkingDirectoryURL`, `Dimming`, `LinkPolicy`/`URLDetector`/`LinkFinder`, `TypedInput`, `PasteWarning` |
| `vthost` | macOS, Linux | headless host CLI: `run`, `replay`, `dump`, `bench`, `smoke`; the terminal esctest and vttest drive |
| `LegendsUI` | macOS | design system: tokens, `LegendsPalette` in the SwiftUI environment, `NeonSwitchStyle`, `NeonSlider`, `Wordmark999`, `NeonBorder`, `Starfield`, `Tagline` |
| `RenderKit` | macOS | `FontRegistry` (the bundled fonts, for this process), `FontSet` (SF Mono or a named family, real or slanted italics, an italic family, the Nerd Font symbols), `GlyphRasterizer` (CoreText, language-aware fallback, private-use characters from the symbols font, emoji fit to their cells), `Shaders` (compiled at launch; dimming and stars), `SurfaceRenderer` (three frames in flight, atlas uploads), `OffscreenRenderer` (render and read back) |
| `TerminalUI` | macOS | `TerminalSurfaceView`: the grid, Metal drawing on a display link that pauses when idle, keys and input methods, the mouse, selection, the pasteboard, links, the frame-rate policy |
| `DeathRaceApp` | macOS | the AppKit app: `PitLaneWindowController` (tabs of split panes and their chrome, Armed and Dangerous, the WRLD sidebar), `PaneController` (one shell or session on a host), Hear Me Calling, the Settings window, `WRLDService` (WRLD for the app), the WRLD window, the New Host and Wishing Well sheets, `KeychainSecretStore`/`DeviceOwnerPresence`, `ConfigStore`/`ConfigWatcher`, menus, About, the icon |
| `DeathRace` | macOS | executable; `--smoke-test` runs the headless end-to-end check, `--write-icon` draws the iconset, `--render-chrome` (debug builds) pictures every theme |

## Decisions

### Our own engine, with a referee

We write the VT engine (`VTCore`). It is the longest part of the project, so it is held to
external standards from day one: esctest (run through `vthost`, with a known-failures ratchet),
libFuzzer, differential tests against SwiftTerm (a test-only dependency in a separate package,
never in the app), and a corpus of recorded real-app sessions with golden final screens. The
view reads screens through `SurfaceSession`, so a stand-in engine could be swapped in if
`VTCore` ever blocks a milestone.

### One thread per session, no shared engine

SwiftTerm found that a lock shared between the parse thread and the main thread lets the
parser barge back in and stall the main thread for seconds. So no engine is shared:

```
 Session thread (one per tab; QoS userInitiated when focused, utility in background tabs)
   poll([pty, wakeFD])                      blocks: zero work at idle
   PTY readable → read into a 64 KiB batch until EAGAIN (Darwin PTYs hand back ~1 KiB per read)
                → terminal.feed(batch) → write replies → check for a password prompt
                → rows changed, input drained, synchronized output (2026) not holding:
                    publish ONE coalesced ScreenDelta, wake main
   wakeFD → input (backpressured) · resize (reflow + TIOCSWINSZ) · fetchRows · search · ack · visibility
 Main thread (v1)
   NSView.displayLink → apply delta to MirrorGrid → ack → rebuild changed rows → present
                      → nothing new for N ticks → pause the link (0 frames at idle)
   keyDown → KeyEncoder (mirrored modes) → session.send; never a blocking write on main
   cursor blink: a Core Animation layer animation, no app wakeups; stops after 30 s idle
```

As built: the thread also polls a child-exit descriptor (a kqueue on macOS, a pidfd on Linux),
so a shell's exit is seen even while a background job keeps the terminal open. Resizes
coalesce to the last one and reach the engine before the program, so its redraw finds the new
size. Typing returns a scrolled-back view to the bottom. Synchronized output holds a frame for
at most a second. Debug builds send every delta through `DeltaCodec`. The tests run real
shells, and CI runs them under Thread Sanitizer.

Nothing a program does can grow memory without bound or starve the app's commands:

| What | Bound |
| --- | --- |
| Output read before commands are handled again | 1 MiB or 20 ms, whichever comes first |
| Output read after the shell exits (a background job can keep a Linux terminal open) | 1 MiB or 100 ms, then hang up |
| Typed input waiting for the shell | 16 MiB; `send` refuses more |
| Replies waiting for a program that does not read them | 1 MiB; later batches are dropped whole |
| Events waiting for the app | folded: one bell, the latest title, directory, progress and clipboard write, the newest 16 notifications and 64 prompt marks |
| Combining marks on one cell | 32; the scrollback budget counts them |
| Work per byte | REP and the tab-count sequences cost what the characters they print cost |

`CAMetalDisplayLink` on a background run loop is reported never to fire on macOS, so v1
renders on main through `NSView.displayLink`. If p95 frame CPU on main exceeds 2 ms, encoding
moves to a render thread signalled from main.

### ScreenProtocol: built now for the daemon later

A `ScreenDelta` carries generation, version, size, the viewport's row ids, cursor, modes,
changed rows (each with its own styles and graphemes) and events. It is current state, not a
log: a newer delta replaces an unsent one, at most one is in flight per client, and a
generation mismatch triggers a full snapshot. Each delta names the version it builds on, and a
mirror applies it only if it holds exactly that state; otherwise it asks for a snapshot, and
the session forgets everything the app took, so the snapshot cannot build on a delta the app
dropped. The session builds a delta without holding the mailbox lock; if the app takes one
meanwhile, the session builds again on the one taken. Phases 1–6 pass deltas in-process;
`legendsd` will send the same encoded bytes over XPC.

The session owns each client's viewport. Rows travel by id, so scrolling sends only the new
line, and a viewport scrolled back into history stays on the same lines while output arrives
below. Scrolling never changes a row's version; only content changes do. Every delta also
carries the viewport's line number (`Terminal.linesScrolledOff`, which counts every line
that ever left the top of the screen, kept or not), so a line keeps its number while output
scrolls and history is trimmed: selections hold on to text by line number, and
`Session.text(in:generation:)` reads ranges that reach back into history the app never had.
Questions to a session (that text, the foreground process) are always answered, with nil
once the session has ended. A randomized test
feeds random output in random chunks (with resizes, screen switches and scrollback trimming),
sends every delta through the codec, and checks that the app's mirror equals a fresh snapshot
after each one. The decoder is defensive: counts are checked against the bytes that remain
before anything is allocated, and invalid scalars, colors and tags are rejected.

### VTCore design

- **Parser.** Paul Williams' DEC/ANSI state machine, written as a `switch` per state and
  generic over its handler, so the hot loop has no protocol dispatch. The plan called for
  tables generated by a `vtgen` tool; a switch on a small enum compiles to the same jump
  table, can be checked against the published state diagram line by line, and has no
  generator to keep in sync. If a profile ever shows dispatch itself is hot, tables are a
  local change. Printable ASCII runs are found eight bytes at a time (SWAR) and written one
  row segment at a time. UTF-8 is decoded in the ground state, with one U+FFFD per maximal
  subpart. Colon sub-parameters (`38:2::r:g:b`, `4:3`) keep a per-parameter "colon follows"
  bit. 8-bit C1 controls are ignored; OSC, DCS and APC strings cap at 8 MiB, parameters at 32.
- **Grid: rows, not pages.** A screen is an array of `Row` objects, and scrollback is a ring
  of them under a byte budget (50 MB). Cells are 8 bytes: a 21-bit scalar, a width state
  (narrow, wide, spacer tail, spacer head), grapheme, protected and hyperlink bits, and a
  16-bit style index. Each row interns its own styles. That departs from Ghostty's per-page,
  reference-counted style tables for two reasons: a row is self-contained when it travels in
  a `ScreenDelta`, and a row never needs more distinct styles than it has cells, so the
  16-bit index cannot overflow and compaction is one pass over one row. The extra scalars of
  multi-scalar characters live in a per-row side table. Scrolling and scroll regions move row
  references; nothing is copied, and retired rows are recycled.
- **Damage tracking.** Every row has a stable id and a version from a clock both screens
  share; the session sends rows whose version moved. A `generation` bumps on screen switches,
  resizes and resets, which means "redraw everything".
- **Unicode.** Width and grapheme properties are generated from Unicode 18.0 by
  `scripts/gen-unicode-tables.py`, which records the SHA-256 of every input file. With mode
  2027 (on by default) graphemes decide width: ZWJ sequences, skin-tone modifiers, flags and
  VS16 emoji are one character. `CSI ? 2027 l` returns to code-point widths.
- **Side effects are data.** Replies (device attributes, cursor reports) are bytes for the
  PTY; titles, bells, notifications, clipboard writes, progress and prompt marks are events.
  The engine never touches the system, which keeps it testable on Linux and movable into the
  daemon.
- **Replies never echo a program's text.** Reply injection, where a program makes the
  terminal type its text into the shell, is a classic terminal vulnerability. So the window
  title cannot be reported, XTGETTCAP answers only names that decode as hex, and OSC 52 reads
  are refused.
- Kitty keyboard protocol in v1, with a flag stack per screen; synchronized output (2026)
  with a 1 s watchdog; DECRQCRA only in test mode, because it lets a program read the screen.

### Process spawning in C

After `fork()` only async-signal-safe calls are allowed, and Swift cannot promise that. `CPTY`
blocks signals across the fork, resets dispositions in the child, makes the slave the
controlling terminal, closes inherited descriptors (`close_range` on Linux) and execs. Shells
get `TERM=xterm-256color`: a custom TERM breaks every SSH host that lacks its terminfo.

Teardown closes the master before waiting for the child, and never waits without a limit. On
macOS the last close of a terminal's slave side waits for unread output to drain while the
master is open, so a shell whose final prompt nobody read cannot finish exiting: waiting for
it first deadlocks. Linux does not drain on close, so only macOS CI catches this.

### An AppKit shell, SwiftUI inside

The app is an `NSApplication`, not SwiftUI's `App`. A terminal needs things only AppKit gives:
close and quit confirmation sheets (`.terminateLater`), a responder chain that carries Copy,
Paste and Bigger/Smaller to the focused terminal view, and full control of the title bar.
SwiftUI draws what is mostly forms and lists: the Settings window and Hear Me Calling's rows,
hosted in AppKit, reading the theme as a `LegendsPalette` from the environment.

### The Pit Lane window

**Our own tabs.** Each window holds tabs of split panes. Native window tabs could not hold
splits or draw gradient pills, so they are off (`allowsAutomaticWindowTabbing = false`), which
gives up tearing a tab off into a window by dragging and Merge All Windows. Move Tab to New
Window moves a tab's views and sessions untouched.

**The controllers.**
- `PitLaneWindowController` owns a `WindowModel` (AppCore: tabs, each a `SplitTree` of panes,
  the active pane, zoom) and keeps the views in step with it: the title row, a `PaneAreaView`
  per tab, the status bar.
- `PaneController` owns one shell: its session, title, directory, exit, clipboard requests
  and link clicks.
- `AppDelegate` keeps the windows, the settings file and its watcher, Secure Keyboard Entry
  and the Settings window.

**The title row.**
- The content runs under a transparent title bar with no toolbar: an empty toolbar would
  make the row tall but would take the clicks of the pills under it.
- The traffic lights are moved to the middle of the 46 pt row after each layout pass, as
  Electron's `trafficLightPosition` does.
- A window test checks that a click on a pill reaches the pill.

**Nothing in the chrome draws per frame.**
- The NeonBorder is gradient strips and arcs, not masks.
- The glow is a `shadowPath`.
- Panes not in use are faded by the terminal's shader through a spare uniform word: no
  overlay layer, no offscreen pass.
- The tab equalizer is a Core Animation animation, stopped by one check after output ends.
- The starfield on the ground is drawn once per size. Behind the text, the background
  shader draws it from the pixel position, in cells FrameBuilder marks.
- The surface's grid layout does nothing when nothing changed, so a chrome layout pass draws
  no terminal frame.

**Hear Me Calling** is an overlay over the window, made when it opens and released when it
closes.
- AppKit owns its geometry and its keys: the search field's delegate takes ↑ ↓ ⇥ ↵ and esc
  before the field editor can.
- SwiftUI draws the rows. `PaletteState` (AppCore) ranks and highlights.
- Actions are validated as their menu items would be, so the palette never offers what
  would do nothing.

### Links

1. **VTCore parses OSC 8.** A printed cell carries the hyperlink flag, and its spare 16 bits
   hold 1 + the index of its link in the row's own table, as styles are kept.
   - Rows travel whole, so scrolling and history carry their tables. Reflow translates
     indexes from row to row.
   - **Limits:** URIs up to 2,048 bytes, ids up to 256, 1,024 links a row. Anything past
     them, or with control characters, prints without a link.
2. **The delta carries the tables** (`DeltaCodec` format 3). Decoding rejects what the
   engine never makes: indexes past the table, a flag without an index, too many links, and
   control characters.
3. **In the app, `LinkFinder` answers which link a cell is in:** the program's own (every cell
   with its id and URI, on any row), else a URL that `URLDetector` finds in the logical line,
   across soft wraps.
4. **The view shows and follows links.**
   - ⌘-hover underlines the link, adding the underline to the frame like composing text, so
     no row is rebuilt.
   - ⌘-click goes through `LinkPolicy`, which opens web and mail links, shows local files in
     Finder and never runs them, asks before other schemes, and refuses scripts.
   - Mouse reports cannot carry ⌘, so programs never see these clicks.
   - Every URI is shown through `LinkPolicy.shown`, which spells out invisible and
     text-reordering characters.

### Frame rate

`FrameRatePolicy` (SurfaceCore) chooses the display link's preferred frame rate range. It is
set only when the answer changes.

| Situation | At most |
| --- | --- |
| Typing, scrolling or selecting in the last second | the display's full rate |
| Output alone (`output-frame-rate-cap`) | 60 fps |
| Low Power Mode (`follow-low-power-mode`) | 60 for input, 30 for output |
| A serious thermal state | 30 fps |

Low Power Mode and the thermal state arrive by notification, and nothing polls.

### Settings are a file

`~/.config/deathrace/config` (or `$XDG_CONFIG_HOME/deathrace/config`) holds `name = value`
lines in Ghostty's style. One table, `ConfigSchema`, names every setting and knows how to read
and write its value, so the parser, the defaults and the commented template Settings… creates
cannot drift apart; a test reads the template back. A line that cannot be used is reported
once, with a suggestion for a misspelled name, and leaves that setting at its default: nothing
in the file can stop the app starting. Reload Configuration applies what changed to open
windows; the settings under New tabs apply to tabs opened afterwards.

The Settings window edits the same file, one line per change, through `ConfigEditor`.
- Every other line stays as it was: comments, order, line endings.
- Writes are atomic, and a settings file that is a symlink stays one.
- `ConfigWatcher` re-reads the file after any editor saves it, in place or by rename, using
  kernel event sources, so nothing runs while nothing changes. Death Race's own writes are
  not reported back to it.
- The file stays the one source of truth, and the window always shows what it says.

### Rendering

`TerminalSurfaceView` (NSView + CAMetalLayer + NSTextInputClient) draws from `MirrorGrid`
through `FrameBuilder`, which lives in the portable `SurfaceCore` so the frame is tested on
Linux: one background color per cell, one instanced glyph draw from CoreText-rasterized
atlases (shelf-packed, coverage and color), and decorations (five underline styles,
strikethrough, overline) drawn by the shader from absolute pixel positions so dots, dashes
and waves continue across cells. Rows are cached by id and version, so output rebuilds only
the rows it changed and a scroll rebuilds one. Colors are resolved in sRGB, as themes and
programs mean them. Box drawing, block elements and the powerline arrows are drawn by
`SpriteRasterizer` at the exact cell size, not taken from the font: lines sit on whole
pixels at the same place in every cell, and a test checks that every arm meets the arm of
the same weight in the next cell at six cell sizes. Frame goldens replay real programs'
recordings through the whole path (engine, deltas, mirror, colors, frame builder) and compare
the colors drawn. Shaders compile at runtime from source, because Xcode 26 ships its Metal
toolchain as a separate download and builds can hang silently without it.
Glow, XDR Neon (EDR), ligature shaping and images are a late polish phase, and they only ever
draw on frames that are happening anyway.

### The Termius layer rides OpenSSH

We never implement SSH crypto. `SSHKit` runs macOS's `/usr/bin/ssh`.

- **One master per host, owned by the app.** Connecting starts
  `ssh -F ~/.deathrace/ssh_config -M -N -o ControlPersist=no …` as Death Race's own child, in
  a session of its own with no terminal. Panes are sessions through it, so a second pane opens
  without a second login. Tunnels are `ssh -F none -S <socket> -O forward|cancel` on it.
  - ControlPersist is never used. It forks the master into the background (`daemon()`), where
    it would outlive the app and its tunnels.
  - The master is known to be connected when its `LocalCommand` prints a marker, which ssh
    runs right after the control socket listens. There is no polling.
- **The vault compiles to an ssh_config** (`GeneratedConfig`):
  - WRLD's settings come first;
  - every block says `ControlMaster no` and `ControlPersist no`;
  - then `Match all` and `Include ~/.ssh/config`, so your own defaults still fill in the rest.
  - Control sockets get fixed names under `~/.deathrace/cm/`. ssh's `%C` hashes this Mac's host
    name, which changes between networks, and socket paths cap at 104 bytes.
  - CI checks the file with real `ssh -G`.
- **Every prompt goes to the app.** Every ssh the app starts gets `deathrace-askpass` as its
  `SSH_ASKPASS` (forced: masters have no terminal), which asks the app's broker
  (`AskpassBroker`) over a Unix socket in a 0700 folder.
  - Before answering, the broker checks the token the app gave that ssh, that the asking
    process is yours and descends from that ssh (at most four levels: jump hops, the helper),
    and that nothing else is in flight for it.
  - It answers a saved password only for the hop ssh named in its own words, after Touch ID
    (`DeviceOwnerPresence`), and only once: asked again, the saved one was wrong.
  - Saved secrets are generic passwords in your login keychain (`KeychainSecretStore`),
    written only after the login they were typed for succeeds.
  - Anything else becomes a question on the window. Cancelling, or declining Touch ID, ends
    the attempt: the master's process group gets SIGTERM, since ssh would otherwise retry.
- **Tested against a real server.** Linux CI starts a throwaway sshd on two loopback
  addresses (`scripts/ci-sshd.sh`) and drives masters, prompts, ProxyJump hops and L/R/D
  tunnels through it end to end. macOS CI runs the helper against the broker and Apple's ssh
  against the generated config.
- **Secure Enclave keys** come from macOS 26's `sc_auth` and `/usr/lib/ssh-keychain.dylib`.
  The new key is told apart by its public key: the handles are downloaded before and after
  the identity is made. It goes onto the host over the first connection's master.
- **A changed host key is a refusal, not a question.** The pane says so and offers Forget the
  Old Key…, taking the file and name from ssh's own "remove with" line; the confirmation shows
  both fingerprints and asks you to check the new one before ssh asks you to trust it.
- **Come & Go** (`TunnelBoard`): OpenSSH can't list what a master forwards, so the app is the
  record. A tunnel joins its host's master as a pane does (starting one if needed, with no
  pane), and a master that ends takes its tunnels with it.
- **What WRLD finds out by itself** (`HostChecks`, `WRLDState`): when each host last
  connected, what it runs (its `/etc/os-release`, over a live master, at most weekly) and how
  quickly the Legends answer (a TCP connect that sends nothing). Checks run only while the
  sidebar or the WRLD window is on screen, five minutes apart with a minute's tolerance and
  after a network change; never through a jump host, never for a host `~/.ssh/config`
  describes (only `ssh -G` would tell how ssh reaches it), and never to a local-network
  address you haven't connected to yourself, since that raises macOS's Local Network question.
  `wrld-check-hosts` and `wrld-host-os` turn them off.

### Typing into many panes, and snippets

Armed and Dangerous hands on what was *typed*, not bytes. The terminal view reports each key,
composed text and paste as a `TypedInput` (the scroll wheel's arrows and the mouse never), and
each armed pane encodes it for its own program, in the modes and Kitty flags that program
set: ↑ is `ESC O A` to vim in application cursor mode and `ESC [ A` at a zsh prompt, and a
paste is bracketed only where asked. One paste question covers every armed pane. The armed
state lives on `TabModel`, so it moves with Move Tab to New Window, and a tab with fewer than
two armed panes disarms itself. Esc stops nothing: it belongs to the programs.

Wishing Well snippets are typed the same way, as a paste (so a shell takes a multi-line
snippet whole) with Return after it as a key when they run. A host's on-connect snippet is
typed as each session through its master starts: never for plain ssh in a pane, where a
login prompt could take it.

### WRLD on screen

The WRLD window (⌘O, SwiftUI) and the sidebar (⌃⌘S, AppKit, so it shows in the CI pictures)
draw from tested models (`WRLDBoard`, `SidebarModel`) and change WRLD only through
`WRLDService`, which saves the vault and posts `.wrldChanged`; everything showing WRLD draws
again from that. Hand edits to `wrld.json` and changes to `~/.ssh/config` are picked up as
they're saved, as the settings file's are.

The SFTP browser (Phase 6) speaks SFTP v3 itself over `ssh -s <host> sftp`, on the same
authenticated connection.

### Signing

`scripts/bundle.sh` signs with the Apple Development identity already in your keychain, the
one MenuGlance uses. Ad-hoc signatures change with every build, which resets Keychain access,
privacy permissions and login-item approval each time.

### The legendsd spike

Phase 7's daemon depends on one question: are shells that a LaunchAgent starts on a
pseudo-terminal still attributed to Death Race by macOS privacy protection (TCC)? Or is the
agent its own responsible process, needing grants of its own? `legendsd-spike` measures it
on a real Mac: [SPIKE.md](SPIKE.md) has the steps and the three possible outcomes.

**Verdict: pending.** It is recorded here with the macOS build it was measured on, and decides
whether Phase 7 builds legendsd as planned, adds an onboarding step for its grants, or keeps
shells in the app and keeps sessions alive another way.

## Known risks

- **The daemon and privacy permissions.** A LaunchAgent is its own responsible process, so
  shells it spawns do not inherit the app's grants, and a PTY host re-parented to launchd has
  hit "Failed to create Attribution Chain" on macOS 26.3.1. Phase 2 includes a one-day spike
  ([above](#the-legendsd-spike)); its verdict goes there before Phase 7 is designed. Never
  double-fork.
- **Secure Keyboard Entry is global.** Enable and disable calls must balance, and it is dropped
  whenever the app deactivates. It cannot see password prompts on the far side of SSH.
- **A password prompt is canonical input with echo off**, not echo off alone. Shells' line
  editors (zsh's ZLE, bash's readline) turn echo off at every prompt and echo keys
  themselves, but they read in raw mode; getpass and readpassphrase (sudo, ssh) read a line in
  canonical mode. The mode is checked when output arrives, and those readers turn echo off
  before printing their prompt, so the prompt reveals it. Checking echo alone would have
  enabled Secure Keyboard Entry at every zsh prompt. macOS CI caught it: Linux's `/bin/sh` is
  dash, which has no line editor.
- **The notch is shared with MenuGlance.** A DistributedNotificationCenter handshake makes
  MenuGlance hide its island while Lucid Dreams is open.
- **CI's GPU is virtual.** macOS runners are VMs with a paravirtual Metal device. The renderer
  tests and the smoke test's render run there, and every run keeps the corpus screens it
  rendered as an artifact for review. Pixel goldens, which need a real GPU's antialiasing,
  run on a Mac with `make test-render`.

## Roadmap

| Phase | What |
| --- | --- |
| 0 | Visual spec (design system + canvas), scaffold, CI, cloud session hook |
| 1 | VTCore, ScreenProtocol, SessionKit, vthost; esctest, fuzzing, corpus, benchmarks |
| 2 | First pixels: CPTY on Darwin, TerminalSurfaceView, RenderKit v1, tabs; daemon spike |
| 3 | Pit Lane shell: tab pills, splits, Hear Me Calling, the Settings window, 8 themes, fonts, links, frame-rate policy (the WRLD sidebar moved to Phase 4, with its content) |
| 4 | Termius layer: WRLD (vault, window, sidebar), app-owned ssh masters and askpass with Touch ID, Secure Enclave keys, Come & Go tunnels, Wishing Well snippets, Armed and Dangerous |
| 5 | Lucid Dreams: the notch quick terminal |
| 6 | Maze: the SFTP browser |
| 7 | Legends Never Die: `legendsd` keeps sessions alive |
| 8 | Conversations, Fast and Ring Ring: shell integration, blocks, timers, alerts |
| 9 | Renderer polish: glow, XDR Neon, ligatures, inline images |
