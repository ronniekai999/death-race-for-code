# Death Race for Code

A native macOS terminal: Termius's host and SSH workflow, Terminal.app's native feel, and the
best ideas from Ghostty, iTerm2 and Warp. It runs its own terminal engine and its own Metal
renderer, draws nothing at all while idle, and wears the Juice WRLD look it shares with
MenuGlance.

L E G E N D S   N E V E R   D I E

## Status

Phase 3, the Pit Lane shell, is built and waiting on the side-by-side review only a Mac can
make. Each window holds tabs of split panes under chrome drawn in the theme's colors:

- **Tabs and panes:** gradient tab pills that reorder, show an equalizer while a background
  tab prints and a dot for a bell; splits with a NeonBorder on the pane in use, the others
  dimmed; headers, draggable dividers, zoom and keys for all of it.
- **Hear Me Calling (⇧⌘P):** every action, pane, theme and Settings page, found by typing;
  themes preview on the window as you move through them.
- **Settings:** a window that edits the settings file line by line, and live reload when
  anything else edits it.
- **Eight themes,** from Legends Never Die to the light Righteous, with Monaspace and
  Nerd Font symbols bundled, so prompt icons draw with any font, and a starfield.
- **Links:** ⌘-hover and ⌘-click on OSC 8 links (`ls --hyperlink=auto`) and on URLs in the
  text, through a policy that never runs a file and asks before unusual schemes.
- **Energy:** idle still draws nothing; output is capped at 60 fps, lower in Low Power Mode
  or when the Mac is hot, while typing keeps the display's full rate.

What is left is the hands-on pass in [docs/MANUAL-TESTS.md](docs/MANUAL-TESTS.md). CI keeps
a picture of the window in every theme (the `chrome-preview` artifact) for the review.

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
  Sources/SessionKit/    one thread per shell, publishing deltas
  Sources/ConfigKit/     the settings file: schema, parser, diagnostics, template
  Sources/SurfaceCore/   the terminal view's logic, apart from AppKit and Metal
  Sources/LegendsUI/     the design system in SwiftUI (macOS)
  Sources/RenderKit/     fonts and the Metal renderer (macOS)
  Sources/TerminalUI/    the terminal view (macOS)
  Sources/DeathRaceApp/  the app: windows, tabs, menus, settings (macOS)
  Tools/vthost/          headless host for the engine: run, replay, bench, smoke
Tools/VTFuzz/            libFuzzer target (a package of its own)
Tools/VTDiff/            VTCore next to SwiftTerm, the referee (a package of its own)
App/                     Info.plist and entitlements for the bundle
scripts/                 bundle.sh, esctest.sh, record-corpus.sh, gen-unicode-tables.py,
                         install-swift-linux.sh
docs/                    architecture, design, naming, performance, conformance
```

## Principles

- **Idle is free.** No timers, no frames, no polling when nothing happens.
- **The engine is ours and it is checked.** esctest, vttest, fuzzing and recorded sessions on
  every change; a comparison with SwiftTerm every week.
- **SSH crypto is not ours.** The Termius layer drives macOS's OpenSSH, including its native
  Secure Enclave keys.
- **The theme lives in names and visuals.** Copy stays plain and helpful.
