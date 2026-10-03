# Death Race for Code

A native macOS terminal: Termius's host and SSH workflow, Terminal.app's native feel, and the
best ideas from Ghostty, iTerm2 and Warp. It runs its own terminal engine and its own Metal
renderer, draws nothing at all while idle, and wears the Juice WRLD look it shares with
MenuGlance.

L E G E N D S   N E V E R   D I E

## Status

Phase 0, the scaffold: the package, a first-lap app window, the pseudo-terminal layer and its
tests, the first piece of the engine, CI, and the design work below. The terminal surface
arrives in Phase 2. See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) for the whole roadmap.

- Mockups (12 boards): https://claude.ai/artifact/A7ti39oW56UDr8FyTqguVd
- Design system, Legends Never Die: https://claude.ai/artifact/SYrFpKuxmKj2m6kTioXe6G

## Build

On your Mac (macOS 26 or later, Xcode 26):

```sh
make run      # build, bundle, sign with your Apple Development identity, open
make test     # every test, macOS and portable
make smoke    # bundle, then run the app's headless --smoke-test
```

On Linux (the engine and pseudo-terminal layers are portable):

```sh
make install-swift-linux   # swift.org toolchain 6.3.3, signature-verified
make test                  # portable targets only
make lint
```

To work in Xcode, open `Packages/DeathRaceKit/Package.swift`.

## Layout

```
Packages/DeathRaceKit/   one SwiftPM package; macOS-only targets appear only on macOS
  Sources/CPTY/          process spawning in C (fork/exec are not safe to drive from Swift)
  Sources/PTYKit/        pseudo-terminals, shell launch, the smoke test
  Sources/VTCore/        the terminal engine
  Sources/LegendsUI/     the design system in SwiftUI (macOS)
  Sources/DeathRaceApp/  the app (macOS)
  Tools/vthost/          headless host for the engine
App/                     Info.plist and entitlements for the bundle
scripts/                 bundle.sh, install-swift-linux.sh
docs/                    architecture, design, naming, performance, conformance
```

## Principles

- **Idle is free.** No timers, no frames, no polling when nothing happens.
- **The engine is ours and it is checked.** esctest, fuzzing, differential tests and recorded
  sessions on every change.
- **SSH crypto is not ours.** The Termius layer drives macOS's OpenSSH, including its native
  Secure Enclave keys.
- **The theme lives in names and visuals.** Copy stays plain and helpful.
