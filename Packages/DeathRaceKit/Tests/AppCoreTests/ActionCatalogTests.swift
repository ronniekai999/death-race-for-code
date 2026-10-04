import ConfigKit
import PTYKit
import Testing

@testable import AppCore

@Suite struct ActionCatalogTests {
    @Test func everyActionIsListedOnce() {
        #expect(
            ActionCatalog.all.map(\.id) == ActionID.allCases.filter { id in ActionCatalog.all.contains { $0.id == id } }
        )
        #expect(Set(ActionCatalog.all.map(\.id)) == Set(ActionID.allCases))
        #expect(ActionCatalog.all.count == ActionID.allCases.count)
    }

    @Test func noTwoActionsShareAShortcut() {
        var seen: [KeyShortcut: ActionID] = [:]
        for action in ActionCatalog.all {
            for shortcut in [action.shortcut].compactMap({ $0 }) + action.alternates {
                #expect(seen[shortcut] == nil, "\(shortcut) is both \(seen[shortcut]!) and \(action.id)")
                seen[shortcut] = action.id
            }
        }
    }

    @Test func shortcutsAreWrittenAsMacOSWritesThem() {
        #expect(ActionCatalog.action(.splitDown).shortcut?.description == "⇧⌘D")
        #expect(ActionCatalog.action(.equalizePanes).shortcut?.description == "⌃⌘=")
        #expect(ActionCatalog.action(.closeTab).shortcut?.description == "⌥⌘W")
        #expect(ActionCatalog.action(.zoomPane).shortcut?.description == "⇧⌘↩")
        #expect(ActionCatalog.action(.focusPaneLeft).shortcut?.description == "⌥⌘←")
        #expect(ActionCatalog.action(.hearMeCalling).shortcut?.description == "⇧⌘P")
        #expect(KeyShortcut(.character("k"), [.command, .option, .shift, .control]).description == "⌃⌥⇧⌘K")
    }

    @Test func commandKClearsAsInEveryMacTerminal() {
        #expect(ActionCatalog.action(.clearToStart).shortcut == KeyShortcut(.character("k")))
        #expect(ActionCatalog.action(.clearScrollback).shortcut == KeyShortcut(.character("k"), [.command, .option]))
    }

    @Test func titlesFollowTheirCase() {
        for action in ActionCatalog.all {
            // Sentence case: only the first word starts with a capital, apart from names.
            let words = action.paletteTitle.split(separator: " ").dropFirst()
            let names: Set<Substring> = [
                "Death", "Race", "for", "Code", "Secure", "Keyboard", "Entry", "Hear", "Me", "Calling",
            ]
            for word in words where word.first?.isUppercase == true {
                #expect(names.contains(word), "\(action.paletteTitle) is not in sentence case")
            }
            #expect(action.menuTitle.first?.isUppercase == true)
        }
    }

    @Test func theKeysReferenceListsNumberedShortcuts() {
        let window = ActionCatalog.reference.first { $0.group == .window }!
        #expect(window.rows.first?.shortcut == "⌘1 – ⌘9")
        #expect(window.rows.contains { $0.shortcut == "⇧⌘]" })
        let shortcutCount = ActionCatalog.reference.reduce(0) { $0 + $1.rows.count }
        #expect(shortcutCount == ActionCatalog.all.filter { $0.shortcut != nil }.count + 2)
    }
}

@Suite struct ShellLaunchPlanTests {
    let environment = ["HOME": "/Users/ronnie", "PATH": "/opt/homebrew/bin:/usr/bin", "SHELL": "/bin/zsh"]
    let executables: Set<String> = ["/bin/zsh", "/opt/homebrew/bin/fish", "/usr/bin/fish"]

    func launch(_ config: Config, directory: String? = nil) -> ShellLaunch {
        ShellLaunchPlan.launch(
            config: config, directory: directory, environment: environment, appVersion: "0.3.0",
            isExecutable: { executables.contains($0) })
    }

    @Test func aCommandIsFoundOnThePath() {
        var config = Config()
        config.command = "fish --login"
        let plan = launch(config)
        #expect(plan.executable == "/opt/homebrew/bin/fish")
        #expect(plan.arguments == ["fish", "--login"])
    }

    @Test func aMissingCommandFallsBackToTheLoginShell() {
        var config = Config()
        config.command = "nushell"
        let plan = launch(config)
        #expect(plan.executable != "nushell")
        #expect(plan.arguments.first?.hasPrefix("-") == true)
    }

    @Test func workingDirectories() {
        var config = Config()
        #expect(launch(config, directory: "/tmp").workingDirectory == "/tmp")
        #expect(launch(config).workingDirectory == "/Users/ronnie")
        config.workingDirectory = .home
        #expect(launch(config, directory: "/tmp").workingDirectory == "/Users/ronnie")
        config.workingDirectory = .path("~/code")
        #expect(launch(config, directory: "/tmp").workingDirectory == "/Users/ronnie/code")
        config.workingDirectory = .path("~")
        #expect(launch(config).workingDirectory == "/Users/ronnie")
    }

    @Test func pathsWithASlashAreTakenAsGiven() {
        #expect(
            ShellLaunchPlan.resolve("/usr/bin/fish", path: nil, isExecutable: { $0 == "/usr/bin/fish" })
                == "/usr/bin/fish")
        #expect(ShellLaunchPlan.resolve("./fish", path: nil, isExecutable: { _ in false }) == nil)
    }
}
