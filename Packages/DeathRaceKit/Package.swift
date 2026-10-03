// swift-tools-version: 6.2
import PackageDescription

// Death Race for Code.
//
// One package with two halves:
//
// * Portable targets (CPTY, PTYKit, VTCore, ScreenProtocol, SessionKit, vthost) build and
//   test on Linux as well as macOS. The terminal engine is developed test-first in a Linux
//   container with no Mac in the loop, and the same code runs inside the app on macOS.
//
// * macOS targets (LegendsUI, DeathRaceApp, DeathRace) exist only when the manifest is
//   evaluated on macOS, so `swift test` on Linux never tries to compile AppKit or SwiftUI.
//
// No third-party dependencies: the first build cannot fail on dependency resolution.

var products: [Product] = [
    .library(name: "VTCore", targets: ["VTCore"]),
    .library(name: "PTYKit", targets: ["PTYKit"]),
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
    .target(name: "VTCore"),
    .executableTarget(
        name: "vthost",
        dependencies: ["VTCore", "PTYKit"],
        path: "Tools/vthost"
    ),
    .testTarget(name: "PTYKitTests", dependencies: ["PTYKit"]),
    .testTarget(name: "VTCoreTests", dependencies: ["VTCore"]),
]

#if os(macOS)
    products += [
        .library(name: "LegendsUI", targets: ["LegendsUI"]),
        .executable(name: "DeathRace", targets: ["DeathRace"]),
    ]
    targets += [
        // Design system: the Legends Never Die tokens and components shared with MenuGlance.
        // SwiftUI only, no engine types, so it stays previewable on its own.
        .target(name: "LegendsUI"),
        .target(name: "DeathRaceApp", dependencies: ["LegendsUI", "PTYKit", "VTCore"]),
        .executableTarget(name: "DeathRace", dependencies: ["DeathRaceApp"]),
    ]
#endif

let package = Package(
    name: "DeathRaceKit",
    platforms: [.macOS("26.0")],
    products: products,
    targets: targets,
    swiftLanguageModes: [.v6]
)
