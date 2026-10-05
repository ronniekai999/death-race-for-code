// swift-tools-version: 6.2
import PackageDescription

// Death Race for Code.
//
// One package with two halves:
//
// * Portable targets (CPTY, PTYKit, VTCore, ScreenProtocol, SessionKit, ConfigKit, SurfaceCore,
//   Vault, SSHKit, SFTPKit, AppCore, vthost, deathrace-askpass) build and test on Linux as well as macOS. The engine, and everything the
//   terminal view and the app do apart from AppKit and Metal, is developed test-first in a
//   Linux container with no Mac in the loop, and the same code runs inside the app on macOS.
//
// * macOS targets (LegendsUI, RenderKit, TerminalUI, DeathRaceApp, DeathRace) exist only when
//   the manifest is evaluated on macOS, so `swift test` on Linux never tries to compile AppKit,
//   Metal or SwiftUI.
//
// No third-party dependencies: the first build cannot fail on dependency resolution.

var products: [Product] = [
    .library(name: "VTCore", targets: ["VTCore"]),
    .library(name: "PTYKit", targets: ["PTYKit"]),
    .library(name: "IPCKit", targets: ["IPCKit"]),
    .library(name: "ScreenProtocol", targets: ["ScreenProtocol"]),
    .library(name: "SessionKit", targets: ["SessionKit"]),
    .library(name: "SessionIPC", targets: ["SessionIPC"]),
    .library(name: "ConfigKit", targets: ["ConfigKit"]),
    .library(name: "SurfaceCore", targets: ["SurfaceCore"]),
    .library(name: "Vault", targets: ["Vault"]),
    .library(name: "SSHKit", targets: ["SSHKit"]),
    .library(name: "SFTPKit", targets: ["SFTPKit"]),
    .library(name: "AppCore", targets: ["AppCore"]),
    .executable(name: "vthost", targets: ["vthost"]),
    .executable(name: "deathrace-askpass", targets: ["deathrace-askpass"]),
]

var targets: [Target] = [
    // Process spawning lives in C: after fork() only async-signal-safe calls are allowed,
    // which Swift cannot promise.
    .target(
        name: "CPTY",
        linkerSettings: [.linkedLibrary("util", .when(platforms: [.linux]))]
    ),
    .target(name: "PTYKit", dependencies: ["CPTY"]),
    // Unix-domain sockets, frames, and who is at the other end: what the askpass broker and
    // the session daemon both need, with nothing of either in it.
    .target(name: "IPCKit", dependencies: ["CPTY"]),
    .target(
        name: "VTCore",
        swiftSettings: [
            // The parser and grid touch class properties on every byte; runtime exclusivity
            // checks were a third of the time. Debug builds, where every test runs, keep them.
            .unsafeFlags(["-enforce-exclusivity=unchecked"], .when(configuration: .release))
        ]
    ),
    // What a session sends the app: screen deltas, the mirror that applies them, and the
    // byte codec the session daemon will use.
    .target(name: "ScreenProtocol", dependencies: ["VTCore"]),
    // One thread per session owns its pseudo-terminal and engine, and publishes deltas.
    .target(name: "SessionKit", dependencies: ["PTYKit", "VTCore", "ScreenProtocol"]),
    // The session daemon and the app's end of it: the wire, the registry, and a session
    // that lives in another process.
    .target(name: "SessionIPC", dependencies: ["SessionKit", "ScreenProtocol", "PTYKit", "VTCore", "IPCKit"]),
    // The settings file: its schema, parser, diagnostics and template.
    .target(name: "ConfigKit", dependencies: ["VTCore"]),
    // What a terminal view does, apart from AppKit and Metal: cell geometry, colors, the
    // frame to draw, selection, key routing. Tested here so the macOS layer stays thin.
    .target(name: "SurfaceCore", dependencies: ["VTCore", "ScreenProtocol", "SessionKit", "ConfigKit"]),
    // What the app does apart from AppKit: windows of tabs of split panes, the actions and
    // their shortcuts, the palette's matching, the status line. The app's logic, tested
    // here, as SurfaceCore is the terminal view's.
    .target(name: "AppCore", dependencies: ["ConfigKit", "PTYKit", "Vault"]),
    // WRLD: saved hosts, groups, snippets and keys, as the JSON file you can keep in a
    // dotfiles repo. Foundation only, and never a secret.
    .target(name: "Vault"),
    // The Termius layer's OpenSSH side: reading ~/.ssh/config, the config WRLD compiles to,
    // ssh's command lines, prompts and their answers, and what a master's errors mean. Runs
    // macOS's own ssh; no SSH crypto of ours.
    .target(name: "SSHKit", dependencies: ["Vault", "PTYKit", "CPTY", "IPCKit"]),
    // Maze: an SFTP v3 client we speak ourselves over a host's existing ssh connection
    // (`ssh … -s sftp`). The packet codec, the client, the transfer queue and the local-file
    // seam are portable and Linux-tested against a real sftp-server.
    .target(name: "SFTPKit", dependencies: ["Vault", "PTYKit", "CPTY", "SSHKit"]),
    // ssh's SSH_ASKPASS: hands each question to the app's broker and prints its answer.
    // The app bundles it in Contents/MacOS.
    .executableTarget(name: "deathrace-askpass", dependencies: ["SSHKit"]),
    .executableTarget(
        name: "vthost",
        dependencies: ["VTCore", "PTYKit", "SurfaceCore"],
        path: "Tools/vthost"
    ),
    .testTarget(name: "PTYKitTests", dependencies: ["PTYKit", "CPTY"]),
    .testTarget(name: "IPCKitTests", dependencies: ["IPCKit", "CPTY", "PTYKit"]),
    .testTarget(name: "VTCoreTests", dependencies: ["VTCore"]),
    .testTarget(name: "ScreenProtocolTests", dependencies: ["ScreenProtocol", "VTCore"]),
    .testTarget(name: "SessionKitTests", dependencies: ["SessionKit", "ScreenProtocol", "PTYKit", "VTCore"]),
    .testTarget(
        name: "SessionIPCTests",
        dependencies: ["SessionIPC", "SessionKit", "ScreenProtocol", "PTYKit", "VTCore", "IPCKit"]),
    .testTarget(name: "ConfigKitTests", dependencies: ["ConfigKit", "VTCore"]),
    .testTarget(
        name: "SurfaceCoreTests", dependencies: ["SurfaceCore", "VTCore", "ScreenProtocol", "SessionKit", "ConfigKit"]),
    .testTarget(name: "AppCoreTests", dependencies: ["AppCore", "ConfigKit", "PTYKit", "Vault"]),
    .testTarget(name: "VaultTests", dependencies: ["Vault"]),
    // Depends on the helper so `swift test` builds it: the tests run it against the broker.
    .testTarget(
        name: "SSHKitTests", dependencies: ["SSHKit", "Vault", "PTYKit", "IPCKit", "deathrace-askpass"]),
    .testTarget(name: "SFTPKitTests", dependencies: ["SFTPKit", "SSHKit", "Vault", "PTYKit", "deathrace-askpass"]),
]

#if os(macOS)
    products += [
        .library(name: "LegendsUI", targets: ["LegendsUI"]),
        .library(name: "RenderKit", targets: ["RenderKit"]),
        .library(name: "TerminalUI", targets: ["TerminalUI"]),
        .executable(name: "DeathRace", targets: ["DeathRace"]),
        .executable(name: "legendsd-spike", targets: ["legendsd-spike"]),
    ]
    targets += [
        // Design system: the Legends Never Die tokens and components shared with MenuGlance.
        // SwiftUI only, no engine types, so it stays previewable on its own.
        .target(name: "LegendsUI"),
        // Metal and CoreText: fonts, glyphs and the renderer.
        .target(name: "RenderKit", dependencies: ["SurfaceCore"]),
        // The terminal view: drawing, keys, input methods, the mouse and the pasteboard.
        .target(
            name: "TerminalUI",
            dependencies: ["RenderKit", "SurfaceCore", "SessionKit", "ScreenProtocol", "ConfigKit", "VTCore"]),
        .target(
            name: "DeathRaceApp",
            dependencies: [
                "LegendsUI", "TerminalUI", "RenderKit", "SurfaceCore", "AppCore", "SessionKit", "ScreenProtocol",
                "ConfigKit", "PTYKit", "VTCore", "Vault", "SSHKit", "SFTPKit",
            ]),
        .executableTarget(name: "DeathRace", dependencies: ["DeathRaceApp", "RenderKit"]),
        // Temporary: the one-day privacy-permission spike for legendsd (docs/SPIKE.md).
        .executableTarget(name: "legendsd-spike", dependencies: ["PTYKit"], path: "Tools/legendsd-spike"),
        .testTarget(
            name: "RenderKitTests", dependencies: ["RenderKit", "SurfaceCore", "ConfigKit", "ScreenProtocol", "VTCore"]),
        // The window and its tabs and panes, driven headless with stand-in sessions.
        .testTarget(
            name: "DeathRaceAppTests",
            dependencies: [
                "DeathRaceApp", "AppCore", "TerminalUI", "SurfaceCore", "SessionKit", "ScreenProtocol", "ConfigKit",
                "PTYKit", "VTCore", "SSHKit", "Vault", "SFTPKit",
            ]),
    ]
#endif

let package = Package(
    name: "DeathRaceKit",
    platforms: [.macOS("26.0")],
    products: products,
    targets: targets,
    swiftLanguageModes: [.v6]
)
