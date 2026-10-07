# Death Race for Code

A native macOS terminal: Termius's host and SSH workflow, Terminal.app's native feel, and the
best ideas from Ghostty, iTerm2 and Warp. It runs its own terminal engine and its own Metal
renderer, draws nothing at all while idle, and wears the Juice WRLD look it shares with
MenuGlance.

L E G E N D S   N E V E R   D I E

## Status

Phases 1 to 6 are merged and green on both CIs: the engine, the window, the Pit Lane, the
Termius layer, Lucid Dreams — the quick terminal that drops out of the notch — and Maze, the
SFTP browser. Phase 7, **Legends Never Die**, is written: the daemon and both ends of its wire
are tested on Linux as two real processes, including the `kill -9` criterion, and the app's
half waits for the hands-on pass in [docs/MANUAL-TESTS.md](docs/MANUAL-TESTS.md). Phase 8,
**Conversations, Fast and Ring Ring**, is written too: our own shell integration for zsh, bash
and fish, a rail and a band and a duration beside each command, personal bests that outlive a
launch, jump-to-prompt and whole-block selection, progress in a tab's pill, and a word when a
long command finishes while you are looking elsewhere.

- **WRLD, your hosts:** kept in `wrld.json` next to the settings file, which never holds a
  secret. Hosts in your `~/.ssh/config` join with one click and keep using that file, which
  WRLD never changes. The WRLD window (⌘O) has cards, groups, Legends, keys, known hosts and
  an inspector; the sidebar (⌃⌘S) keeps them next to your panes.
- **Connections through macOS's own OpenSSH.** Each host gets one master that the app owns,
  so a second pane or a split on the same host opens without logging in again, and quitting
  leaves no ssh behind. Saved passwords stay in your login Keychain and reach ssh only after
  Touch ID; ssh's questions (passwords, codes, a new host's key) come as sheets.
- **Secure Enclave keys,** made from the New Host sheet and put on the host over its first
  connection. macOS asks for Touch ID at each login.
- **Come & Go:** local, remote and SOCKS tunnels, turned on and off on a live connection,
  with "⇄ 2 tunnels" in the status bar.
- **Wishing Well:** snippets with `{{placeholders}}`, inserted or run from the sidebar, Hear
  Me Calling or WRLD, and a snippet per host that is typed as each session starts.
- **Armed and Dangerous (⇧⌘I):** typing goes to every pane in the tab, each encoding it for
  its own program, under an orange-to-pink border. Esc still belongs to the programs.
- **Maze,** a window per host: this Mac's folder beside the host's, with the transfers
  between them on gradient bars. It speaks SFTP version 3 itself, as a second channel on the
  master a pane already opened — so it opens with no new login. Upload and download, drags
  between the panes, and Finder files dropped on the host's side.
- **Lucid Dreams (⌥Space):** one terminal that springs out of the notch and keeps its
  session across hide and show. It doesn't switch apps, and it yields the notch to
  MenuGlance.
- **Legends Never Die:** a `legendsd` the app starts holds the pseudo-terminals and the
  engines, so local shells outlive the app — quit, crash or update — and come back in the
  windows and tabs they were in, with their scrollback. Quitting detaches and asks nothing;
  closing a pane still ends its shell. Sessions on a host are not kept, and the setting says
  so. The daemon is never required: anything that goes wrong leaves you with a session in the
  app and a line in the status bar saying as much.
- **Hear Me Calling** finds hosts, snippets and tunnels as well.

Phase 3 built the Pit Lane: tabs of split panes under gradient pills, Hear Me Calling
(⇧⌘P), a Settings window with live reload, eight themes, bundled fonts, OSC 8 links and a
frame-rate policy. CI keeps a picture of the window in every theme (the `chrome-preview`
artifact) for its side-by-side review, which is in the same file.

Phase 2 put the engine on screen: Metal drawing, the keyboard, input methods and the Kitty
protocol, the mouse, selection and the clipboard, Secure Keyboard Entry, and an idle
window that draws no frames. Its Mac checks are in the same file.

Phase 1 built the engine. It covers the v1 scope and passes 95% of xterm's conformance suite
on that scope (esctest, ratcheted in CI). It reflows on resize, handles Unicode 18 graphemes,
encodes keys for the Kitty keyboard protocol, passes vttest's classic screens, and replays
recorded vim, nvim, tmux, htop, fzf and nano sessions to their golden screens. It runs one
thread per shell that publishes screen deltas, and it survives libFuzzer. See
[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) for the roadmap and
[docs/CONFORMANCE.md](docs/CONFORMANCE.md) for what is checked and how.

## Settings

Settings live in `~/.config/deathrace/config` (or `$XDG_CONFIG_HOME/deathrace/config`), one
`name = value` per line. **Settings…** (⌘,) opens a window that changes one line of the file
at a time and leaves the rest as you wrote it; **Open Settings File** opens it in your text
editor, with every setting commented out at its default and explained. Saved edits apply to
the open windows at once, from either place. A line Death Race cannot use is reported, with
a suggestion when a name looks misspelled, and leaves that setting at its default.

```ini
theme = lucid-dreams
font-family = SF Mono
font-size = 14
# Comments go on their own line: a # later in a line is part of the value, as in colors.
option-as-meta = left
palette = 1=#FF5277
```

`~/.deathrace/run` holds what is running rather than what you keep: the session daemon's
socket, the lock that makes it the only one, and its log. It is yours and `0700`, and it is
empty once nothing is running.

WRLD lives beside the settings file, in `wrld.json`: hosts, groups, snippets, tunnels, and
which key file each host uses (never a key itself), as JSON you can keep in a dotfiles
repository. Edit it in the WRLD window or by hand; either way the
open windows follow. What changes on its own (when a host last connected, what it runs, how
quickly it answers) goes to `~/.deathrace/state.json` instead, so the file you keep doesn't
churn. Passwords live only in the login Keychain.

- Mockups (12 boards): https://claude.ai/artifact/A7ti39oW56UDr8FyTqguVd
- Design system, Legends Never Die: https://claude.ai/artifact/SYrFpKuxmKj2m6kTioXe6G

## Build

On your Mac (macOS 26 or later, Xcode 26):

```sh
make run          # build, bundle, sign with your Apple Development identity, open
make test         # every test, macOS and portable
make smoke        # bundle, then run the app's headless --smoke-test
make test-render  # recorded programs' screens drawn by the GPU, against PNG goldens
```

`CONFIG=debug make run` adds a Debug menu: frame and latency stats, and the legendsd spike.

On Linux (the engine, session and pseudo-terminal layers are portable):

```sh
make install-swift-linux   # swift.org toolchain 6.3.3, signature-verified
make test                  # portable targets only
eval "$(scripts/ci-sshd.sh)" && make test   # as root in a container: with a loopback sshd
make esctest               # xterm's conformance suite against the engine (python3)
make fuzz                  # libFuzzer, FUZZ_SECONDS=60 by default
make bench                 # engine throughput, release build
make vtdiff                # next to SwiftTerm: throughput, and every corpus screen
make lint
```

`vthost` hosts the engine headless: `vthost run -- program` is a terminal for any program
(`--record` saves its output), `vthost replay file` prints the screen a recording leaves,
`vthost frame file` prints, in color, the frame the app would draw for it, and `vthost bench`
measures.

To work in Xcode, open `Packages/DeathRaceKit/Package.swift`.

## Layout

```
Packages/DeathRaceKit/   one SwiftPM package; macOS-only targets appear only on macOS
  Sources/CPTY/          process spawning in C (fork/exec are not safe to drive from Swift)
  Sources/PTYKit/        pseudo-terminals, shell launch, hang-up, the smoke test
  Sources/VTCore/        the terminal engine: parser, screens, reflow, Unicode, input encoding
  Sources/ScreenProtocol/ screen deltas, the app's mirror, the byte codec
  Sources/SessionKit/    the session seam, and one thread per shell publishing deltas
  Sources/IPCKit/        Unix sockets, frames, and who is at the other end
  Sources/SessionIPC/    Legends Never Die: the wire, the daemon, and the app's end of it
  Sources/legendsd/      the session daemon: it holds the shells so they outlive the app
  Sources/ConfigKit/     the settings file: schema, parser, diagnostics, template
  Sources/Vault/         WRLD's data: hosts, groups, snippets, tunnels, wrld.json
  Sources/SSHKit/        OpenSSH, driven: generated config, masters, tunnels, askpass broker
  Sources/deathrace-askpass/ the SSH_ASKPASS helper that asks the app
  Sources/AppCore/       the app's logic apart from AppKit: windows, actions, palette, WRLD
  Sources/SurfaceCore/   the terminal view's logic, apart from AppKit and Metal
  Sources/LegendsUI/     the design system in SwiftUI (macOS)
  Sources/RenderKit/     fonts and the Metal renderer (macOS)
  Sources/TerminalUI/    the terminal view (macOS)
  Sources/DeathRaceApp/  the app: windows, tabs, menus, settings, WRLD (macOS)
  Sources/DeathRace/     the executable (macOS)
  Tools/vthost/          headless host for the engine: run, replay, bench, smoke
  Tools/legendsd-probe/  stands in for the app in the daemon's tests, which have to kill it
Tools/VTFuzz/            libFuzzer target (a package of its own)
Tools/VTDiff/            VTCore next to SwiftTerm, the referee (a package of its own)
App/                     Info.plist and entitlements for the bundle
scripts/                 bundle.sh, esctest.sh, record-corpus.sh, gen-unicode-tables.py,
                         install-swift-linux.sh, ci-sshd.sh (a throwaway sshd for the
                         SSH tests), wrld-homework.sh (Secure Enclave facts from your Mac)
docs/                    architecture, design, naming, performance, conformance
```

## Principles

- **Idle is free.** No timers, no frames, no polling when nothing happens.
- **The engine is ours and it is checked.** esctest, vttest, fuzzing and recorded sessions on
  every change; a comparison with SwiftTerm every week.
- **SSH crypto is not ours.** The Termius layer drives macOS's OpenSSH, including its native
  Secure Enclave keys.
- **The theme lives in names and visuals.** Copy stays plain and helpful.
