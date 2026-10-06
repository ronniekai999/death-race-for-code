import AppCore
import Foundation
import Testing
import VTCore

/// zsh, bash and fish, for real, in a pseudo-terminal, with what they print fed through the
/// engine — because a disagreement between what a script writes and what the parser expects is
/// invisible to either side on its own.
///
/// `.timeLimit(.minutes(1))` is not decoration: Phase 6's actual CI failure was a hang that
/// ate the whole 25-minute job.
@Suite("Real shells", .serialized, .enabled(if: TestShells.shouldRun), .timeLimit(.minutes(1)))
@MainActor struct RealShellTests {

    // MARK: - zsh

    @Test func zshReportsACommandsTextDurationAndExit() throws {
        let zsh = try #require(TestShells.path("zsh"), TestShells.missing("zsh"))
        let rig = try ShellRig(shell: .zsh, executable: zsh, rc: "PS1='$ '\n")
        #expect(rig.waitForFirstPrompt())

        #expect(rig.run("sleep 0.3", awaiting: ShellRig.commandEnd))
        let record = try #require(rig.commands().last)
        #expect(record.text == "sleep 0.3")
        #expect(record.exitCode == 0)
        // Real elapsed time, not a placeholder: generous at the top because CI is shared.
        let duration = try #require(record.durationMilliseconds)
        #expect(duration >= 250 && duration < 20_000)
    }

    @Test func zshReportsAFailingCommandsExitCode() throws {
        let zsh = try #require(TestShells.path("zsh"), TestShells.missing("zsh"))
        let rig = try ShellRig(shell: .zsh, executable: zsh, rc: "PS1='$ '\n")
        #expect(rig.waitForFirstPrompt())

        // A subshell, not `exit 7`: that would end the shell, so no `D` could ever follow it.
        #expect(rig.run("(exit 7)", awaiting: ShellRig.commandEnd))
        #expect(rig.commands().last?.exitCode == 7)
    }

    /// The escaping is a contract with `Terminal.unescapeVSCode`. Comparing the decoded text
    /// to what was typed is what proves both halves agree — a near-miss would show up here as
    /// a mangled command rather than as nothing at all.
    @Test func zshEscapingRoundTripsThroughTheEngine() throws {
        let zsh = try #require(TestShells.path("zsh"), TestShells.missing("zsh"))
        let rig = try ShellRig(shell: .zsh, executable: zsh, rc: "PS1='$ '\n")
        #expect(rig.waitForFirstPrompt())

        let typed = #"echo 'a;b\c'"#
        #expect(rig.run(typed, awaiting: ShellRig.commandEnd))
        #expect(rig.commands().last?.text == typed)
        // And the wire really did carry it escaped, rather than a bare `;` ending the
        // parameter early and the engine happening to cope.
        #expect(rig.raw.contains(#"\x3b"#))
    }

    /// A command written across two lines is ordinary. Its newline becomes one space rather
    /// than nothing, so the halves do not run together into `echo aecho b`.
    @Test func zshKeepsACommandWithALineBreakReadable() throws {
        let zsh = try #require(TestShells.path("zsh"), TestShells.missing("zsh"))
        let rig = try ShellRig(shell: .zsh, executable: zsh, rc: "PS1='$ '\n")
        #expect(rig.waitForFirstPrompt())

        #expect(rig.run("echo one &&\\\necho two", awaiting: ShellRig.commandEnd))
        let text = try #require(rig.commands().last?.text)
        #expect(text.contains("echo one"))
        #expect(text.contains("echo two"))
        #expect(!text.contains("\n"))
        #expect(!text.contains("oneecho"), "a line break was dropped rather than made a space")
    }

    /// `ZDOTDIR` is inherited, so without our `.zshrc` putting the user's own back, every zsh
    /// started from this one would read our files instead of theirs — for ever.
    @Test func zshDoesNotLeakItsZdotdirIntoANestedShell() throws {
        let zsh = try #require(TestShells.path("zsh"), TestShells.missing("zsh"))
        let rig = try ShellRig(shell: .zsh, executable: zsh, rc: "PS1='$ '\n")
        #expect(rig.waitForFirstPrompt())

        #expect(rig.run("echo ZD=${ZDOTDIR:-unset}", awaiting: ShellRig.commandEnd))
        #expect(rig.raw.contains("ZD=\(rig.home)"), "ZDOTDIR was not handed back to the user's own")
        #expect(!rig.raw.contains("shell-integration/zsh"), "our folder leaked into the shell")
    }

    /// A prompt framework replaces the hook arrays wholesale when it loads, which is why ours
    /// are appended and sourced after yours. A stand-in for Oh My Zsh: an rc file that sets
    /// its own `precmd_functions` before we touch them.
    @Test func zshKeepsAPromptFrameworksOwnHooks() throws {
        let zsh = try #require(TestShells.path("zsh"), TestShells.missing("zsh"))
        let rc = """
            PS1='$ '
            framework_precmd() { print -n 'FRAMEWORK' }
            precmd_functions=(framework_precmd)
            """
        let rig = try ShellRig(shell: .zsh, executable: zsh, rc: rc)
        #expect(rig.waitForFirstPrompt())

        #expect(rig.run("echo hi", awaiting: ShellRig.commandEnd))
        #expect(rig.raw.contains("FRAMEWORK"), "our hooks replaced the framework's")
        #expect(rig.commands().last?.text == "echo hi", "the framework's hooks replaced ours")
    }

    // MARK: - bash

    @Test func bashReportsACommandsTextDurationAndExit() throws {
        let bash = try #require(TestShells.path("bash"), TestShells.missing("bash"))
        let directory = try #require(ShellIntegration.directory())
        let rig = try ShellRig(
            shell: .bash, executable: bash, rc: "PS1='$ '\n\(ShellIntegration.bashLine(directory: directory))\n")
        #expect(rig.waitForFirstPrompt())

        #expect(rig.run("sleep 0.3", awaiting: ShellRig.commandEnd))
        let record = try #require(rig.commands().last)
        #expect(record.text == "sleep 0.3")
        #expect(record.exitCode == 0)
        let duration = try #require(record.durationMilliseconds)
        #expect(duration >= 250 && duration < 20_000)
    }

    /// The `DEBUG` trap fires for every command, including the lines of our own script and
    /// everything inside `PROMPT_COMMAND`. The first thing it reported must be what was typed.
    @Test func bashDoesNotReportItsOwnSourceAsACommand() throws {
        let bash = try #require(TestShells.path("bash"), TestShells.missing("bash"))
        let directory = try #require(ShellIntegration.directory())
        let rig = try ShellRig(
            shell: .bash, executable: bash, rc: "PS1='$ '\n\(ShellIntegration.bashLine(directory: directory))\n")
        #expect(rig.waitForFirstPrompt())

        #expect(rig.run("echo hi", awaiting: ShellRig.commandEnd))
        #expect(rig.commands().first?.text == "echo hi")
    }

    @Test func bashEscapingRoundTripsThroughTheEngine() throws {
        let bash = try #require(TestShells.path("bash"), TestShells.missing("bash"))
        let directory = try #require(ShellIntegration.directory())
        let rig = try ShellRig(
            shell: .bash, executable: bash, rc: "PS1='$ '\n\(ShellIntegration.bashLine(directory: directory))\n")
        #expect(rig.waitForFirstPrompt())

        let typed = #"echo 'a;b\c'"#
        #expect(rig.run(typed, awaiting: ShellRig.commandEnd))
        #expect(rig.commands().last?.text == typed)
    }

    // MARK: - fish

    @Test func fishReportsACommandsTextDurationAndExit() throws {
        let fish = try #require(TestShells.path("fish"), TestShells.missing("fish"))
        let rig = try ShellRig(shell: .fish, executable: fish, rc: "function fish_prompt\n  echo -n '$ '\nend\n")
        #expect(rig.waitForFirstPrompt())

        #expect(rig.run("sleep 0.3", awaiting: ShellRig.commandEnd))
        let record = try #require(rig.commands().last)
        #expect(record.text == "sleep 0.3")
        #expect(record.exitCode == 0)
        let duration = try #require(record.durationMilliseconds)
        #expect(duration >= 250 && duration < 20_000)
    }

    /// Our snippet is in `vendor_conf.d`, which fish reads *before* `config.fish`. Wrapping
    /// the prompt at load time would copy fish's default and then be thrown away the moment
    /// the user's own `fish_prompt` was defined, which is what most fish configs do.
    @Test func fishKeepsTheUsersOwnPromptAndStillMarksIt() throws {
        let fish = try #require(TestShells.path("fish"), TestShells.missing("fish"))
        let rc = "function fish_prompt\n  echo -n 'MYPROMPT> '\nend\n"
        let rig = try ShellRig(shell: .fish, executable: fish, rc: rc)
        #expect(rig.waitForFirstPrompt())

        #expect(rig.run("echo hi", awaiting: ShellRig.commandEnd))
        #expect(rig.raw.contains("MYPROMPT>"), "the user's own prompt was replaced")
        #expect(rig.commands().last?.text == "echo hi")
    }

    @Test func fishEscapingRoundTripsThroughTheEngine() throws {
        let fish = try #require(TestShells.path("fish"), TestShells.missing("fish"))
        let rig = try ShellRig(shell: .fish, executable: fish, rc: "function fish_prompt\n  echo -n '$ '\nend\n")
        #expect(rig.waitForFirstPrompt())

        let typed = #"echo 'a;b\c'"#
        #expect(rig.run(typed, awaiting: ShellRig.commandEnd))
        #expect(rig.commands().last?.text == typed)
    }

    // MARK: - What a program prints is not what the shell said

    /// A command's own output can print anything, a mark included. The engine takes marks from
    /// the stream by design, so what this pins down is that the shell's own `D` — which comes
    /// after the output — is the one whose exit code ends up on the row.
    @Test func aFakeMarkInOutputDoesNotBecomeTheExitCode() throws {
        let zsh = try #require(TestShells.path("zsh"), TestShells.missing("zsh"))
        let rig = try ShellRig(shell: .zsh, executable: zsh, rc: "PS1='$ '\n")
        #expect(rig.waitForFirstPrompt())

        // The command prints a mark claiming it failed with 99, then really succeeds. Waiting
        // on `;dur=` rather than on the mark itself, because the forged one is a real escape
        // sequence — `printf` interprets the `\033` — so waiting for the mark matched the
        // forgery and returned before the shell had said anything. Only the shell sends `dur`.
        #expect(rig.run(#"printf '\033]133;D;99\a'"#, awaiting: ";dur="))
        let records = rig.commands()
        // The shell's own `D` is the last word on how the command went, and no record anywhere
        // claims the forged status. The reason is worth knowing rather than assuming: the
        // forgery printed no newline, so the shell's own `D` lands on the same row and simply
        // overwrites it. A program that moved the cursor first could still leave a record of
        // its own on another row — the engine takes marks from the stream by design and cannot
        // tell whose bytes they are, which is true of every terminal that reads OSC 133.
        #expect(records.last?.exitCode == 0, "a mark printed by the program was the final word")
        #expect(!records.contains { $0.exitCode == 99 }, "a forged status became a command's outcome")
    }
}
