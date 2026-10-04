// swift-tools-version: 6.0
import PackageDescription

// The referee: SwiftTerm, at a pinned commit (v1.20.0), fed the same bytes as VTCore. A
// package of its own so SwiftTerm never comes near the app.
let package = Package(
    name: "VTDiff",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(path: "../../Packages/DeathRaceKit"),
        .package(
            url: "https://github.com/migueldeicaza/SwiftTerm.git",
            revision: "5d14406844143538cd8f8851d2d8a67c1fe443e5"),
    ],
    targets: [
        .executableTarget(
            name: "vtdiff",
            dependencies: [
                .product(name: "VTCore", package: "DeathRaceKit"),
                .product(name: "SwiftTerm", package: "SwiftTerm"),
            ],
            swiftSettings: [.unsafeFlags(["-enforce-exclusivity=unchecked"], .when(configuration: .release))])
    ]
)
