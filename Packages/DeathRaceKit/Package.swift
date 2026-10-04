// swift-tools-version: 6.2
import PackageDescription

// Death Race for Code.
//
// One package with two halves:
//
// * Portable targets (CPTY, PTYKit, VTCore, ScreenProtocol, SessionKit, ConfigKit, SurfaceCore,
//   vthost) build and test on Linux as well as macOS. The engine and everything a terminal view
//   does apart from AppKit and Metal is developed test-first in a Linux container with no Mac in
//   the loop, and the same code runs inside the app on macOS.
//
// * macOS targets (LegendsUI, RenderKit, TerminalUI, DeathRaceApp, DeathRace) exist only when
//   the manifest is evaluated on macOS, so `swift test` on Linux never tries to compile AppKit,
//   Metal or SwiftUI.
//
// No third-party dependencies: the first build cannot fail on dependency resolution.

var products: [Product] = [
    .library(name: "VTCore", targets: ["VTCore"]),
    .library(name: "PTYKit", targets: ["PTYKit"]),
    .library(name: "ScreenProtocol", targets: ["ScreenProtocol"]),
    .library(name: "SessionKit", targets: ["SessionKit"]),
    .library(name: "ConfigKit", targets: ["ConfigKit"]),
    .library(name: "SurfaceCore", targets: ["SurfaceCore"]),
    .executable(name: "vthost", targets: ["vthost"]),
]

var targets: [Target] = [
    // Process spawning lives in C: after fork() only async-signal-safe calls are allowed,
    // which Swift cannot promise.
    .target(
        name: "CPTY",
        linkerSettings: [.linkedLibrary("util", .when(platforms: [.linux]))]
    ),
    .target(name: "PTYKit", dependencies: ["CPTY"]),
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
    // The settings file: its schema, parser, diagnostics and template.
    .target(name: "ConfigKit", dependencies: ["VTCore"]),
    // What a terminal view does, apart from AppKit and Metal: cell geometry, colors, the
    // frame to draw, selection, key routing. Tested here so the macOS layer stays thin.
    .target(name: "SurfaceCore", dependencies: ["VTCore", "ScreenProtocol", "SessionKit", "ConfigKit"]),
    .executableTarget(
        name: "vthost",
        dependencies: ["VTCore", "PTYKit", "SurfaceCore"],
        path: "Tools/vthost"
    ),
    .testTarget(name: "PTYKitTests", dependencies: ["PTYKit"]),
    .testTarget(name: "VTCoreTests", dependencies: ["VTCore"]),
    .testTarget(name: "ScreenProtocolTests", dependencies: ["ScreenProtocol", "VTCore"]),
    .testTarget(name: "SessionKitTests", dependencies: ["SessionKit", "ScreenProtocol", "PTYKit", "VTCore"]),
    .testTarget(name: "ConfigKitTests", dependencies: ["ConfigKit", "VTCore"]),
    .testTarget(
        name: "SurfaceCoreTests", dependencies: ["SurfaceCore", "VTCore", "ScreenProtocol", "SessionKit", "ConfigKit"]),
]

#if os(macOS)
    products += [
        .library(name: "LegendsUI", targets: ["LegendsUI"]),
        .library(name: "RenderKit", targets: ["RenderKit"]),
        .library(name: "TerminalUI", targets: ["TerminalUI"]),
        .executable(name: "DeathRace", targets: ["DeathRace"]),
    ]
    targets += [
        // Design system: the Legends Never Die tokens and components shared with MenuGlance.
        // SwiftUI only, no engine types, so it stays previewable on its own.
        .target(name: "LegendsUI"),
        // Metal and CoreText: fonts, glyphs and the renderer.
        .target(name: "RenderKit", dependencies: ["SurfaceCore"]),
        // The terminal view: drawing, keys, input methods, the mouse and the pasteboard.
        .target(name: "TerminalUI", dependencies: ["RenderKit", "SurfaceCore", "ConfigKit", "VTCore"]),
        .target(
            name: "DeathRaceApp",
            dependencies: ["LegendsUI", "TerminalUI", "RenderKit", "ConfigKit", "PTYKit", "VTCore"]),
        .executableTarget(name: "DeathRace", dependencies: ["DeathRaceApp"]),
        .testTarget(name: "RenderKitTests", dependencies: ["RenderKit", "SurfaceCore"]),
    ]
#endif

let package = Package(
    name: "DeathRaceKit",
    platforms: [.macOS("26.0")],
    products: products,
    targets: targets,
    swiftLanguageModes: [.v6]
)
