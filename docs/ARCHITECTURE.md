# Architecture

Death Race for Code is a native macOS terminal with its own terminal engine, its own Metal
renderer, a Termius-style SSH layer built on the system's OpenSSH, and a session daemon that
keeps shells alive when the app quits. This file records the decisions and the reasons for
them. Read it before changing anything that moves bytes between the shell and the screen.

## The shape

```
 DeathRace.app (UI process)                           legendsd (Phase 7, LaunchAgent)
 ┌────────────────────────────────────────────┐       ┌───────────────────────────────┐
 │ DeathRaceApp  SwiftUI shell: WRLD sidebar, │       │ SessionHost over XPC          │
 │   tabs, splits, Hear Me Calling, settings, │       │  owns PTYs + VTCore engines   │
 │   LucidDreams panel                        │       │  survives quit/crash/update   │
 │ TerminalUI  NSView: keys/IME/mouse/select  │◀─────▶│  same ScreenDelta bytes       │
 │ RenderKit   Metal: atlas, cells, cursor    │       └───────────────────────────────┘
 │ LegendsUI   tokens + Neon components       │
 │ MirrorGrid  screen copy the renderer draws │
 ├────────────────────────────────────────────┤
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
| `PTYKit` | macOS, Linux | `PseudoTerminal` (non-blocking master, resize, echo state, reaping), `ShellLaunch`, `SmokeTest` |
| `VTCore` | macOS, Linux | the engine; so far the streaming UTF-8 decoder |
| `vthost` | macOS, Linux | headless host CLI: `smoke` now; `run`, `replay`, `dump`, `bench`, esctest later |
| `LegendsUI` | macOS | design system: tokens, `Wordmark999`, `NeonBorder`, `Starfield`, `Tagline` |
| `DeathRaceApp` | macOS | the SwiftUI app; Phase 0 shows a first-lap window and checks the login shell |
| `DeathRace` | macOS | executable; `--smoke-test` runs the headless end-to-end check |

## Decisions

### Our own engine, with a referee

We write the VT engine (`VTCore`). It is the longest part of the project, so it is held to
external standards from day one: esctest (run through `vthost`, with a known-failures ratchet),
libFuzzer, differential tests against SwiftTerm (a test-only dependency in a separate package,
never in the app), and a corpus of recorded real-app sessions with golden final screens. The
renderer reads screens through `ScreenSource`, so a stand-in engine could be swapped in if
`VTCore` ever blocks a milestone.

### One thread per session, no shared engine

SwiftTerm found that a lock shared between the parse thread and the main thread lets the
parser barge back in and stall the main thread for seconds. So no engine is shared:

```
 Session thread (one per tab; QoS userInitiated when focused, utility in background tabs)
   poll([pty, wakeFD])                      blocks: zero work at idle
   PTY readable → read into a 64 KiB batch until EAGAIN (Darwin PTYs hand back ~1 KiB per read)
                → terminal.feed(batch) → write replies → re-check ECHO for secure input
                → rows changed, input drained, synchronized output (2026) not holding:
                    publish ONE coalesced ScreenDelta, wake main
   wakeFD → input (backpressured) · resize (reflow + TIOCSWINSZ) · fetchRows · search · ack · visibility
 Main thread (v1)
   NSView.displayLink → apply delta to MirrorGrid → ack → rebuild changed rows → present
                      → nothing new for N ticks → pause the link (0 frames at idle)
   keyDown → KeyEncoder (mirrored modes) → session.send; never a blocking write on main
   cursor blink: a Core Animation layer animation, no app wakeups; stops after 30 s idle
```

`CAMetalDisplayLink` on a background run loop is reported never to fire on macOS, so v1
renders on main through `NSView.displayLink`. If p95 frame CPU on main exceeds 2 ms, encoding
moves to a render thread signalled from main.

### ScreenProtocol: built now for the daemon later

A `ScreenDelta` carries generation, version, size, top viewport row id, cursor, modes, changed
rows (each with its own styles and graphemes) and events. It is current state, not a log: a
newer delta replaces an unsent one, at most one is in flight per client, and a generation
mismatch triggers a full snapshot. Phases 1–6 pass deltas in-process; `legendsd` will send the
same encoded bytes over XPC.

### VTCore design

- Paul Williams' DEC/ANSI state machine, with tables generated by `vtgen`; a SIMD/SWAR scan
  for printable ASCII runs; streaming UTF-8 with one U+FFFD per maximal subpart; colon
  sub-parameters (`38:2::r:g:b`, `4:3`).
- Ghostty-style paged grid: 8-byte cells, per-page reference-counted style tables (truecolor
  gradients create unlimited styles), per-page grapheme side tables, scrollback with a byte cap.
- Per-row `UInt64` versions, stable row ids, and a `generation` bumped by resize, reflow and
  alternate-screen switches.
- Width and grapheme tables generated from Unicode 18.0; mode 2027 on by default.
- Kitty keyboard protocol in v1; synchronized output (2026) with a 1 s watchdog; DECRQCRA only
  in test mode, because it lets a program read the screen.

### Process spawning in C

After `fork()` only async-signal-safe calls are allowed, and Swift cannot promise that. `CPTY`
blocks signals across the fork, resets dispositions in the child, makes the slave the
controlling terminal, closes inherited descriptors (`close_range` on Linux) and execs. Shells
get `TERM=xterm-256color`: a custom TERM breaks every SSH host that lacks its terminfo.

### Rendering

`TerminalSurfaceView` (NSView + CAMetalLayer + NSTextInputClient) draws from `MirrorGrid`: a
cols×rows background texture, one instanced glyph draw from CoreText-rasterized atlases, and
decorations in the shader. Shaders compile at runtime from bundled source, because Xcode 26
ships its Metal toolchain as a separate download and builds can hang silently without it.
Glow, XDR Neon (EDR), ligature shaping and images are a late polish phase, and they only ever
draw on frames that are happening anyway.

### The Termius layer rides OpenSSH

We never implement SSH crypto. `SSHKit` runs `/usr/bin/ssh` with ControlMaster
(`ControlPath=~/.deathrace/cm/%C`, since socket paths cap at 104 bytes), supplies passwords
through an askpass helper backed by the Keychain and Touch ID, and creates Secure Enclave keys
with macOS 26's `/usr/lib/ssh-keychain.dylib`. Tunnels are `ssh -O forward/cancel/check` on
the live connection. The SFTP browser speaks SFTP v3 itself over `ssh -s <host> sftp`, on the
same authenticated connection.

### Signing

`scripts/bundle.sh` signs with the Apple Development identity already in your keychain, the
one MenuGlance uses. Ad-hoc signatures change with every build, which resets Keychain access,
privacy permissions and login-item approval each time.

## Known risks

- **The daemon and privacy permissions.** A LaunchAgent is its own responsible process, so
  shells it spawns do not inherit the app's grants, and a PTY host re-parented to launchd has
  hit "Failed to create Attribution Chain" on macOS 26.3.1. Phase 2 includes a one-day spike;
  its verdict goes here before Phase 7 is designed. Never double-fork.
- **Secure Keyboard Entry is global.** Enable and disable calls must balance, and it is dropped
  whenever the app deactivates. It cannot see password prompts on the far side of SSH.
- **The notch is shared with MenuGlance.** A DistributedNotificationCenter handshake makes
  MenuGlance hide its island while Lucid Dreams is open.
- **CI has no GPU.** macOS runners are VMs; renderer golden-image tests skip without a Metal
  device and run locally.

## Roadmap

| Phase | What |
| --- | --- |
| 0 | Visual spec (design system + canvas), scaffold, CI, cloud session hook |
| 1 | VTCore, ScreenProtocol, SessionKit, vthost; esctest, fuzzing, corpus, benchmarks |
| 2 | First pixels: CPTY on Darwin, TerminalSurfaceView, RenderKit v1, tabs; daemon spike |
| 3 | Pit Lane shell: WRLD sidebar, tab pills, splits, palette, settings, 8 themes, fonts |
| 4 | Termius layer: vault, SSH launcher, Secure Enclave keys, tunnels, snippets, broadcast |
| 5 | Lucid Dreams: the notch quick terminal |
| 6 | Maze: the SFTP browser |
| 7 | Legends Never Die: `legendsd` keeps sessions alive |
| 8 | Conversations, Fast and Ring Ring: shell integration, blocks, timers, alerts |
| 9 | Renderer polish: glow, XDR Neon, ligatures, inline images |
