import ConfigKit
import Testing
import Vault

@testable import AppCore

@Suite("Pane launches")
struct PaneLaunchTests {
    let prod = HostRef.vault(HostID(rawValue: "h1"))

    @Test func aLaunchKnowsItsHost() {
        #expect(PaneLaunch.shell.host == nil)
        #expect(PaneLaunch.connection(prod).host == prod)
        #expect(PaneLaunch.plainSSH(.sshConfig(alias: "nas-999")).host == .sshConfig(alias: "nas-999"))
    }

    @Test func aSplitConnectsToTheSameHostThroughItsMaster() {
        #expect(PaneLaunch.shell.forSplit == .shell)
        #expect(PaneLaunch.connection(prod).forSplit == .connection(prod))
        #expect(PaneLaunch.plainSSH(prod).forSplit == .connection(prod))
    }

    @Test func wrldLivesNextToTheSettings() {
        for environment in [[:], ["XDG_CONFIG_HOME": "/x/conf"], ["XDG_CONFIG_HOME": "relative"]] {
            let settings = ConfigLocation.path(environment: environment, home: "/Users/r")
            let wrld = VaultLocation.path(environment: environment, home: "/Users/r")
            #expect(String(settings.dropLast("config".count)) == String(wrld.dropLast("wrld.json".count)))
        }
    }
}
