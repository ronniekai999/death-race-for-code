import DeathRaceApp
import Foundation
import RenderKit

// Top-level code runs on the main thread; `assumeIsolated` says so, so Swift 6 lets it call
// main-actor code.
if CommandLine.arguments.contains("--print-shader-source") {
    print(Shaders.source)
    exit(0)
}
// The app icon's .iconset, for scripts/bundle.sh: `--write-icon DIR`.
if let index = CommandLine.arguments.firstIndex(of: "--write-icon") {
    let arguments = CommandLine.arguments
    let directory = index + 1 < arguments.count ? arguments[index + 1] : "."
    do {
        try AppIcon.writeIconset(to: URL(fileURLWithPath: directory, isDirectory: true))
        exit(0)
    } catch {
        FileHandle.standardError.write(Data("could not write the icon: \(error)\n".utf8))
        exit(1)
    }
}
if CommandLine.arguments.contains("--smoke-test") {
    exit(MainActor.assumeIsolated { DeathRaceSmokeTest.run() })
}
MainActor.assumeIsolated {
    DeathRaceApplication.run()
}
