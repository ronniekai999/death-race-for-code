import DeathRaceApp
import Foundation

if CommandLine.arguments.contains("--smoke-test") {
    exit(DeathRaceSmokeTest.run())
}

// Top-level code runs on the main thread; say so, so Swift 6 lets it start the
// main-actor-isolated app.
MainActor.assumeIsolated {
    DeathRaceApplication.run()
}
