import Foundation
import PTYKit

/// `DeathRace --smoke-test`: the headless end-to-end check macOS CI runs against the bundled
/// app. Uses `zsh -f` so no rc file can change the outcome.
public enum DeathRaceSmokeTest {
    public static func run() -> Int32 {
        let launch = ShellLaunch(
            executable: "/bin/zsh",
            arguments: ["zsh", "-f"],
            environment: ShellLaunch.terminalEnvironment(
                inheriting: ShellLaunch.processEnvironment(),
                appVersion: DeathRaceApplication.version
            )
        )
        do {
            try SmokeTest.run(launch)
            print("Death Race \(DeathRaceApplication.version): smoke test passed")
            return 0
        } catch {
            print("Death Race \(DeathRaceApplication.version): smoke test failed\n\(error)")
            return 1
        }
    }
}
