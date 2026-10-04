// swift-tools-version: 6.2
import PackageDescription

// libFuzzer target for the engine, apart from the main package because libFuzzer supplies
// `main`: this only links with -sanitize=fuzzer. Build and run with `make fuzz`.
let package = Package(
    name: "VTFuzz",
    platforms: [.macOS("26.0")],
    dependencies: [.package(path: "../../Packages/DeathRaceKit")],
    targets: [
        .executableTarget(
            name: "VTFuzz",
            dependencies: [
                .product(name: "VTCore", package: "DeathRaceKit"),
                .product(name: "ScreenProtocol", package: "DeathRaceKit"),
            ]
        )
    ],
    swiftLanguageModes: [.v6]
)
