# Death Race for Code

A native macOS terminal: Termius's host and SSH workflow, Terminal.app's native feel, and the
best ideas from Ghostty, iTerm2 and Warp. It runs its own terminal engine and its own Metal
renderer, draws nothing at all while idle, and wears the Juice WRLD look it shares with
MenuGlance.

L E G E N D S   N E V E R   D I E

## Status

Phase 1, the engine. The terminal engine covers the v1 scope and passes 96% of
xterm's conformance suite on that scope (esctest, ratcheted in CI). It reflows on resize,
handles Unicode 18 graphemes, and encodes keys for the Kitty keyboard protocol. It runs one
thread per shell that publishes screen deltas, and it survives libFuzzer. The app still
shows the first-lap window; the terminal surface arrives in Phase 2. See
[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) for the roadmap and
[docs/CONFORMANCE.md](docs/CONFORMANCE.md) for what is checked and how.

- Mockups (12 boards): https://claude.ai/artifact/A7ti39oW56UDr8FyTqguVd
- Design system, Legends Never Die: https://claude.ai/artifact/SYrFpKuxmKj2m6kTioXe6G

## Build

On your Mac (macOS 26 or later, Xcode 26):

```sh
make run      # build, bundle, sign with your Apple Development identity, open
make test     # every test, macOS and portable
make smoke    # bundle, then run the app's headless --smoke-test
```

On Linux (the engine, session and pseudo-terminal layers are portable):

```sh
make install-swift-linux   # swift.org toolchain 6.3.3, signature-verified
make test                  # portable targets only
make esctest               # xterm's conformance suite against the engine (python3)
make fuzz                  # libFuzzer, FUZZ_SECONDS=60 by default
make bench                 # engine throughput, release build
make lint
```

`vthost` hosts the engine headless: `vthost run -- program` is a terminal for any program,
`vthost replay file` prints the screen a recording leaves, and `vthost bench` measures.

To work in Xcode, open `Packages/DeathRaceKit/Package.swift`.

## Layout

```
Packages/DeathRaceKit/   one SwiftPM package; macOS-only targets appear only on macOS
  Sources/CPTY/          process spawning in C (fork/exec are not safe to drive from Swift)
  Sources/PTYKit/        pseudo-terminals, shell launch, hang-up, the smoke test
  Sources/VTCore/        the terminal engine: parser, screens, reflow, Unicode, input encoding
  Sources/ScreenProtocol/ screen deltas, the app's mirror, the byte codec
  Sources/SessionKit/    one thread per shell, publishing deltas
  Sources/LegendsUI/     the design system in SwiftUI (macOS)
  Sources/DeathRaceApp/  the app (macOS)
  Tools/vthost/          headless host for the engine: run, replay, bench, smoke
Tools/VTFuzz/            libFuzzer target (a package of its own)
App/                     Info.plist and entitlements for the bundle
scripts/                 bundle.sh, esctest.sh, gen-unicode-tables.py, install-swift-linux.sh
docs/                    architecture, design, naming, performance, conformance
```

## Principles

- **Idle is free.** No timers, no frames, no polling when nothing happens.
- **The engine is ours and it is checked.** esctest, fuzzing, differential tests and recorded
  sessions on every change.
- **SSH crypto is not ours.** The Termius layer drives macOS's OpenSSH, including its native
  Secure Enclave keys.
- **The theme lives in names and visuals.** Copy stays plain and helpful.
