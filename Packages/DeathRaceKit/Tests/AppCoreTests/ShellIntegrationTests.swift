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

    /// Not `$HOME`: a shell with no `ZDOTDIR` is not the same as one pointing at the home
    /// folder, even though zsh reads the same files for both, and the scripts restore the
    /// absence so that nothing of ours is left in a nested shell's environment.
    @Test func zshWithNoZdotdirIsGivenNoneBack() {
        let environment = ShellIntegration.adding(to: ["HOME": "/home/r"], shell: .zsh, directory: scripts)
        #expect(environment["DEATHRACE_USER_ZDOTDIR"] == nil)
    }

    /// And a value a parent app run left behind is cleared rather than carried forward, or a
    /// second launch would hand the shell a folder that has nothing to do with it.
    @Test func zshDoesNotInheritAStaleUserZdotdir() {
        let environment = ShellIntegration.adding(
            to: ["HOME": "/home/r", "DEATHRACE_USER_ZDOTDIR": "/stale"], shell: .zsh, directory: scripts)
        #expect(environment["DEATHRACE_USER_ZDOTDIR"] == nil)
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
        // Guarded, so a startup file that outlives an uninstall does not break every new shell.
        #expect(line.hasPrefix("[ -r "))
    }

    /// Single quotes, because the path is read by a shell: in double quotes an app installed
    /// under a folder with a `$` or a backtick in its name would be expanded rather than read,
    /// and a space would need quoting anyway. A quote in the path gets the only spelling a
    /// single-quoted string has for one.
    @Test func theBashLineQuotesAPathTheShellWouldOtherwiseRead() {
        let awkward = URL(fileURLWithPath: "/opt/my $apps/`x`/it's here", isDirectory: true)
        let line = ShellIntegration.bashLine(directory: awkward)
        #expect(line.contains(#"'/opt/my $apps/`x`/it'\''s here/bash/deathrace.bash'"#))
        #expect(!line.contains("\""))
        // And a real bash agrees that this is one word: the quoting is the whole point.
        #expect(line.hasPrefix("[ -r '"))
    }

    @Test func anAlreadyInstalledLineIsRecognised() {
        let line = ShellIntegration.bashLine(directory: scripts)
        #expect(ShellIntegration.isInstalled(in: "PS1='$ '\n\(line)\n", directory: scripts))
        // Reformatted or hand-edited still counts: it is the path that matters, not the line.
        #expect(
            ShellIntegration.isInstalled(
                in: "  source /opt/dr/shell-integration/bash/deathrace.bash\n", directory: scripts))
    }

    @Test func anAlreadyInstalledAwkwardPathIsRecognisedThroughItsQuoting() {
        let awkward = URL(fileURLWithPath: "/opt/it's here", isDirectory: true)
        let line = ShellIntegration.bashLine(directory: awkward)
        #expect(ShellIntegration.isInstalled(in: line, directory: awkward))
    }

    @Test func aCommentedOutLineIsNotInstalled() {
        let line = ShellIntegration.bashLine(directory: scripts)
        #expect(!ShellIntegration.isInstalled(in: "# \(line)\n", directory: scripts))
        #expect(!ShellIntegration.isInstalled(in: "PS1='$ '\n", directory: scripts))
    }

    // MARK: - Which file the offer points at

    /// A pane runs a *login* bash, which reads `~/.bash_profile` and never `~/.bashrc`. The
    /// line has to go where the shell we start will actually read it.
    @Test func theOfferPointsAtTheFileALoginBashReads() {
        let files = ["/home/r/.bash_profile": "export PATH=/opt/bin:$PATH\n"]
        #expect(ShellIntegration.bashProfile(home: "/home/r", contentsOfFile: { files[$0] }) == "/home/r/.bash_profile")
    }

    /// Unless that file already pulls in `~/.bashrc`, which is the usual convention and what
    /// most distributions ship: then the line belongs there, where the non-login interactive
    /// shells other things start will read it too.
    @Test func theOfferFollowsAProfileThatSourcesYourBashrc() {
        let files = ["/home/r/.bash_profile": "[ -f ~/.bashrc ] && . ~/.bashrc\n"]
        #expect(ShellIntegration.bashProfile(home: "/home/r", contentsOfFile: { files[$0] }) == "/home/r/.bashrc")
        // A commented-out one does not count as sourcing it.
        let commented = ["/home/r/.bash_profile": "# . ~/.bashrc\nexport X=1\n"]
        #expect(
            ShellIntegration.bashProfile(home: "/home/r", contentsOfFile: { commented[$0] })
                == "/home/r/.bash_profile")
    }

    /// bash reads the first of the three that exists and no more, so the order is the answer.
    @Test func theOfferFollowsBashsOwnOrderOfPreference() {
        let both = ["/home/r/.bash_login": "export X=1\n", "/home/r/.profile": "export Y=1\n"]
        #expect(ShellIntegration.bashProfile(home: "/home/r", contentsOfFile: { both[$0] }) == "/home/r/.bash_login")
        let only = ["/home/r/.profile": "export Y=1\n"]
        #expect(ShellIntegration.bashProfile(home: "/home/r", contentsOfFile: { only[$0] }) == "/home/r/.profile")
    }

    /// With none of the three there, a login bash reads nothing at all, so naming the first
    /// one costs nothing: creating it adds our line and takes none of yours away.
    @Test func theOfferNamesAProfileToCreateWhenThereIsNone() {
        #expect(ShellIntegration.bashProfile(home: "/home/r", contentsOfFile: { _ in nil }) == "/home/r/.bash_profile")
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
