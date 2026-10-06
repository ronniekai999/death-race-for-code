import ConfigKit
import Foundation
import PTYKit
import Testing

@testable import AppCore

/// The seam, without a shell in sight: which shell an executable is, where the scripts are,
/// and what a session's environment needs. Always runs — only the suite that spawns real
/// shells is gated.
@Suite struct ShellIntegrationTests {

    private let scripts = URL(fileURLWithPath: "/opt/dr/shell-integration", isDirectory: true)

    // MARK: - Which shell is this?

    @Test func aShellIsKnownByTheExecutableThatWillRun() {
        #expect(ShellIntegration.shell(ofExecutable: "/bin/zsh") == .zsh)
        #expect(ShellIntegration.shell(ofExecutable: "/usr/local/bin/bash") == .bash)
        #expect(ShellIntegration.shell(ofExecutable: "/opt/homebrew/bin/fish") == .fish)
        // A version suffix is the same shell, which is how Homebrew installs them.
        #expect(ShellIntegration.shell(ofExecutable: "/usr/local/bin/bash-5.2") == .bash)
        // Anything else gets a session with no integration and no complaint.
        #expect(ShellIntegration.shell(ofExecutable: "/bin/sh") == nil)
        #expect(ShellIntegration.shell(ofExecutable: "/usr/bin/nu") == nil)
        #expect(ShellIntegration.shell(ofExecutable: "") == nil)
    }

    // MARK: - Where are the scripts?

    @Test func theEnvironmentOverrideWinsOverEverything() {
        let found = ShellIntegration.directory(
            environment: ["DEATHRACE_SHELL_INTEGRATION": "/tmp/mine"], fileExists: { _ in true })
        #expect(found?.path == "/tmp/mine")
    }

    @Test func anEmptyOverrideIsNotAnOverride() {
        // Set-but-empty is how a shell spells "unset"; treating it as a path would send every
        // session looking for scripts at "".
        let found = ShellIntegration.directory(
            environment: ["DEATHRACE_SHELL_INTEGRATION": ""], fileExists: { _ in false })
        #expect(found == nil)
    }

    @Test func theRepositoryIsTheLastResort() {
        // No override and no bundle: the committed folder, found by walking up from this
        // package, which is what makes `swift run` from a checkout work.
        let found = ShellIntegration.directory(environment: [:], fileExists: { $0.contains("App/shell-integration") })
        #expect(found?.path.hasSuffix("App/shell-integration") == true)
    }

    @Test func nowhereToLookIsNotAnError() {
        #expect(ShellIntegration.directory(environment: [:], fileExists: { _ in false }) == nil)
    }

    // MARK: - What the environment needs

    @Test func zshIsHandedOurFolderAndGivenItsOwnBack() {
        let environment = ShellIntegration.adding(
            to: ["HOME": "/home/r", "ZDOTDIR": "/home/r/.zsh"], shell: .zsh, directory: scripts)
        #expect(environment["ZDOTDIR"] == "/opt/dr/shell-integration/zsh")
        #expect(environment["DEATHRACE_USER_ZDOTDIR"] == "/home/r/.zsh")
    }

    @Test func zshWithNoZdotdirIsGivenItsHome() {
        let environment = ShellIntegration.adding(to: ["HOME": "/home/r"], shell: .zsh, directory: scripts)
        #expect(environment["DEATHRACE_USER_ZDOTDIR"] == "/home/r")
    }

    @Test func fishIsPrependedToTheDataDirectories() {
        let environment = ShellIntegration.adding(
            to: ["XDG_DATA_DIRS": "/usr/share"], shell: .fish, directory: scripts)
        #expect(environment["XDG_DATA_DIRS"] == "/opt/dr/shell-integration/fish:/usr/share")
    }

    /// Prepending to an empty value would *replace* the default rather than add to it, and
    /// hide fish's own vendor files — a worse outcome than having no integration at all.
    @Test func fishWithNoDataDirectoriesKeepsTheSpecsDefault() {
        let environment = ShellIntegration.adding(to: [:], shell: .fish, directory: scripts)
        #expect(
            environment["XDG_DATA_DIRS"]
                == "/opt/dr/shell-integration/fish:" + ShellIntegration.defaultDataDirectories)
    }

    @Test func fishIsNotAddedTwice() {
        var environment = ShellIntegration.adding(to: [:], shell: .fish, directory: scripts)
        environment = ShellIntegration.adding(to: environment, shell: .fish, directory: scripts)
        let entries = (environment["XDG_DATA_DIRS"] ?? "").split(separator: ":")
        #expect(entries.filter { $0.hasSuffix("shell-integration/fish") }.count == 1)
    }

    /// bash is reached by a line in your own `~/.bashrc`, so there is nothing to put in the
    /// environment for it — and nothing must be, or it would look configured when it is not.
    @Test func bashNeedsNothingInTheEnvironment() {
        let before = ["HOME": "/home/r", "PATH": "/bin"]
        #expect(ShellIntegration.adding(to: before, shell: .bash, directory: scripts) == before)
    }

    @Test func anUnknownShellOrMissingFolderChangesNothing() {
        let before = ["HOME": "/home/r"]
        #expect(ShellIntegration.adding(to: before, shell: nil, directory: scripts) == before)
        #expect(ShellIntegration.adding(to: before, shell: .zsh, directory: nil) == before)
    }

    // MARK: - The one line bash is offered

    @Test func theBashLineLoadsTheScriptAndSaysWhoseItIs() {
        let line = ShellIntegration.bashLine(directory: scripts)
        #expect(line.contains("/opt/dr/shell-integration/bash/deathrace.bash"))
        #expect(line.contains("Death Race for Code"))
        // Guarded, so a bashrc that outlives an uninstall does not break every new shell.
        #expect(line.hasPrefix("[ -r "))
    }

    @Test func anAlreadyInstalledLineIsRecognised() {
        let line = ShellIntegration.bashLine(directory: scripts)
        #expect(ShellIntegration.isInstalled(inBashrc: "PS1='$ '\n\(line)\n", directory: scripts))
        // Reformatted or hand-edited still counts: it is the path that matters, not the line.
        #expect(
            ShellIntegration.isInstalled(
                inBashrc: "  source /opt/dr/shell-integration/bash/deathrace.bash\n", directory: scripts))
    }

    @Test func aCommentedOutLineIsNotInstalled() {
        let line = ShellIntegration.bashLine(directory: scripts)
        #expect(!ShellIntegration.isInstalled(inBashrc: "# \(line)\n", directory: scripts))
        #expect(!ShellIntegration.isInstalled(inBashrc: "PS1='$ '\n", directory: scripts))
    }

    // MARK: - Through the launch the app actually composes

    @Test func aLaunchCarriesTheIntegrationForTheShellItWillRun() {
        var config = Config()
        config.shellIntegration = true
        let launch = ShellLaunchPlan.launch(
            config: config, directory: "/tmp", environment: ["HOME": "/home/r", "SHELL": "/bin/zsh"],
            appVersion: "test", isExecutable: { _ in true }, integration: scripts)
        #expect(launch.environment["ZDOTDIR"] == "/opt/dr/shell-integration/zsh")
    }

    @Test func theSettingTurnsItOffWithoutTouchingAnythingElse() {
        var config = Config()
        config.shellIntegration = false
        let launch = ShellLaunchPlan.launch(
            config: config, directory: "/tmp", environment: ["HOME": "/home/r", "SHELL": "/bin/zsh"],
            appVersion: "test", isExecutable: { _ in true }, integration: scripts)
        #expect(launch.environment["ZDOTDIR"] == nil)
        #expect(launch.environment["TERM"] == "xterm-256color", "the rest of the environment went with it")
    }

    /// `command` replaces argv wholesale, so the shell that will actually run is not the one
    /// `$SHELL` names. Keying on `$SHELL` would set up zsh for a session running fish.
    @Test func aConfiguredCommandDecidesWhichShellIsSetUp() {
        var config = Config()
        config.shellIntegration = true
        config.command = "/opt/homebrew/bin/fish"
        let launch = ShellLaunchPlan.launch(
            config: config, directory: "/tmp", environment: ["HOME": "/home/r", "SHELL": "/bin/zsh"],
            appVersion: "test", isExecutable: { _ in true }, integration: scripts)
        #expect(launch.environment["XDG_DATA_DIRS"]?.hasPrefix("/opt/dr/shell-integration/fish") == true)
        #expect(launch.environment["ZDOTDIR"] == nil, "zsh was set up for a session running fish")
    }
}
