import DeathRaceApp
import Foundation
import RenderKit

// Top-level code runs on the main thread; `assumeIsolated` says so, so Swift 6 lets it call
// main-actor code.
if CommandLine.arguments.contains("--print-shader-source") {
    print(Shaders.source)
    exit(0)
}
if CommandLine.arguments.contains("--smoke-test") {
    exit(MainActor.assumeIsolated { DeathRaceSmokeTest.run() })
}
MainActor.assumeIsolated {
    DeathRaceApplication.run()
}
