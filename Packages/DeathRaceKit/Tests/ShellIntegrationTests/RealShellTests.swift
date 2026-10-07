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
        #expect(!text.contains("\n"))
        // The space is the assertion. `!text.contains("oneecho")`, which used to stand here,
        // held whether or not the line break survived — the `&&\` between the halves kept
        // them apart on its own, so the test could not fail.
        #expect(text.hasSuffix(" echo two"), "the line break did not become a space: \(text)")
    }

    /// `ZDOTDIR` is inherited, so without our `.zshrc` putting the user's own back, every zsh
    /// started from this one would read our files instead of theirs — for ever.
    @Test func zshDoesNotLeakItsZdotdirIntoANestedShell() throws {
        let zsh = try #require(TestShells.path("zsh"), TestShells.missing("zsh"))
        let rig = try ShellRig(shell: .zsh, executable: zsh, rc: "PS1='$ '\n")
        #expect(rig.waitForFirstPrompt())

        // `unset`, not the home folder: this shell was started without a ZDOTDIR, and the
        // variable's absence is itself part of the environment your files were written for.
        #expect(rig.run("echo ZD=${ZDOTDIR:-unset} DR=${DEATHRACE_USER_ZDOTDIR:-unset}", awaiting: ShellRig.commandEnd))
        #expect(rig.raw.contains("ZD=unset DR=unset"), "something of ours was left in the environment")
        #expect(!rig.raw.contains("shell-integration/zsh"), "our folder leaked into the shell")
        // And the three helpers the hand-off is made of are gone with it.
        #expect(rig.run("echo FN=${+functions[__deathrace_yours]}", awaiting: ShellRig.commandEnd))
        #expect(rig.raw.contains("FN=0"), "a helper of ours was left defined in your shell")
    }

    /// The app starts a *login* shell, and zsh reads `.zprofile` between `.zshenv` and
    /// `.zshrc`. With `ZDOTDIR` pointed at our folder for that whole stretch, yours was looked
    /// for in ours and never read — and Homebrew's own instructions put `eval "$(brew
    /// shellenv)"` in `~/.zprofile`, so `brew` and everything it adds to PATH disappeared from
    /// every pane. `.zlogin` is the same stretch at the other end.
    @Test func zshReadsEveryOneOfYourStartupFilesInALoginShell() throws {
        let zsh = try #require(TestShells.path("zsh"), TestShells.missing("zsh"))
        let rig = try ShellRig(
            shell: .zsh, executable: zsh, rc: "PS1='$ '\nexport SAW_ZSHRC=1\n",
            files: [
                ".zshenv": "export SAW_ZSHENV=1\n", ".zprofile": "export SAW_ZPROFILE=1\n",
                ".zlogin": "export SAW_ZLOGIN=1\n",
            ], login: true)
        #expect(rig.waitForFirstPrompt())

        #expect(
            rig.run(
                "echo SAW=${SAW_ZSHENV:-no}${SAW_ZPROFILE:-no}${SAW_ZSHRC:-no}${SAW_ZLOGIN:-no}",
                awaiting: ShellRig.commandEnd))
        #expect(rig.raw.contains("SAW=1111"), "a startup file of yours was skipped")
    }

    /// The XDG layout, which is what `~/.zshenv` is usually for: it sets `ZDOTDIR` to
    /// `~/.config/zsh`, and the rest of your files live there. Taking the value we started
    /// with rather than the one your `.zshenv` left looked for them in the wrong folder, so
    /// the integration quietly did nothing at all — no marks, and our variable left behind in
    /// every child, since only our `.zshrc` ever unset it and it was never reached.
    @Test func zshFollowsAZdotdirYourOwnZshenvSets() throws {
        let zsh = try #require(TestShells.path("zsh"), TestShells.missing("zsh"))
        let rig = try ShellRig(
            shell: .zsh, executable: zsh, rc: "# not this one\n",
            files: [
                ".zshenv": "export ZDOTDIR=$HOME/.config/zsh\n",
                ".config/zsh/.zshrc": "PS1='$ '\nexport SAW_XDG_ZSHRC=1\n",
            ], login: true)
        #expect(rig.waitForFirstPrompt())

        #expect(rig.run("echo XDG=${SAW_XDG_ZSHRC:-no}", awaiting: ShellRig.commandEnd))
        #expect(rig.raw.contains("XDG=1"), "the .zshrc your .zshenv pointed at was not read")
        #expect(rig.commands().last?.text == "echo XDG=${SAW_XDG_ZSHRC:-no}")
        // Handed back to where *you* put it, not to where we found it.
        #expect(rig.run("echo ZD=$ZDOTDIR", awaiting: ShellRig.commandEnd))
        #expect(rig.raw.contains("ZD=\(rig.home)/.config/zsh"))
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

    /// The app starts a *login* bash, which reads `~/.bash_profile` and never `~/.bashrc` — so
    /// the line this offered to add at first was read by nothing a pane runs. That is not a
    /// corner case on a Mac, where Terminal.app and iTerm2 start login shells too, which is
    /// exactly why a Mac bash user keeps their settings in `.bash_profile`.
    @Test func bashIsReachedFromTheFileALoginShellReads() throws {
        let bash = try #require(TestShells.path("bash"), TestShells.missing("bash"))
        let directory = try #require(ShellIntegration.directory())
        let rig = try ShellRig(
            shell: .bash, executable: bash, rc: "# a login bash never reads this\n",
            files: [".bash_profile": "PS1='$ '\n\(ShellIntegration.bashLine(directory: directory))\n"],
            login: true)
        #expect(rig.waitForFirstPrompt())

        #expect(rig.run("echo hi", awaiting: ShellRig.commandEnd))
        #expect(rig.commands().last?.text == "echo hi")
    }

    /// Ours used to be appended to `PROMPT_COMMAND`, so `$?` was whatever the entry before it
    /// returned. With `history -a` — the commonest value there is — every failing command
    /// reported success, which is the one thing a pass/fail mark exists to get right.
    @Test func bashReportsTheRightExitCodeWithAPromptCommandOfYourOwn() throws {
        let bash = try #require(TestShells.path("bash"), TestShells.missing("bash"))
        let directory = try #require(ShellIntegration.directory())
        let rc = """
            PS1='$ '
            PROMPT_COMMAND='history -a'
            \(ShellIntegration.bashLine(directory: directory))
            """
        let rig = try ShellRig(shell: .bash, executable: bash, rc: rc)
        #expect(rig.waitForFirstPrompt())

        #expect(rig.run("false", awaiting: ShellRig.commandEnd))
        #expect(rig.commands().last?.exitCode == 1, "the entry before ours decided the exit code")
    }

    /// `source ~/.bashrc` is an ordinary thing to type, and it runs your rc again — reassigning
    /// `PS1` and `PROMPT_COMMAND`. A guard that skipped everything on the second load left the
    /// shell with our functions defined and nothing calling them, so the marks stopped.
    @Test func bashSurvivesYourRcBeingSourcedAgain() throws {
        let bash = try #require(TestShells.path("bash"), TestShells.missing("bash"))
        let directory = try #require(ShellIntegration.directory())
        let rc = """
            PS1='$ '
            PROMPT_COMMAND='history -a'
            \(ShellIntegration.bashLine(directory: directory))
            """
        let rig = try ShellRig(shell: .bash, executable: bash, rc: rc)
        #expect(rig.waitForFirstPrompt())

        #expect(rig.run("source ~/.bashrc", awaiting: ShellRig.commandEnd))
        #expect(rig.run("false", awaiting: ShellRig.commandEnd))
        let record = try #require(rig.commands().last)
        #expect(record.text == "false")
        #expect(record.exitCode == 1)
        // And the prompt drawn *after* the re-source still says where it ends: the rc put a
        // fresh PS1 in place, and only re-applying the marker every prompt gets it back.
        let afterward = rig.raw.components(separatedBy: "source ~/.bashrc").last ?? ""
        #expect(afterward.contains("133;B"), "PS1 lost its marker when your rc was sourced again")
    }

    /// `$_` is the last argument of the last command, and the `DEBUG` trap is a command like
    /// any other — so without putting it back, `mkdir x && cd $_` cd'd into the name of a
    /// function of ours and failed.
    @Test func bashKeepsTheLastArgumentOfYourCommand() throws {
        let bash = try #require(TestShells.path("bash"), TestShells.missing("bash"))
        let directory = try #require(ShellIntegration.directory())
        let rig = try ShellRig(
            shell: .bash, executable: bash, rc: "PS1='$ '\n\(ShellIntegration.bashLine(directory: directory))\n")
        #expect(rig.waitForFirstPrompt())

        #expect(rig.run("mkdir -p \"$HOME/under\" && cd $_ && pwd", awaiting: ShellRig.commandEnd))
        #expect(rig.commands().last?.exitCode == 0, "$_ was clobbered, so `cd $_` had nowhere to go")
        #expect(rig.raw.contains("\(rig.home)/under"))
    }

    /// `$BASH_COMMAND` holds one simple command at a time, so a line with two of them arrived
    /// as its first half — and an alias arrived already expanded rather than as you wrote it.
    @Test func bashRecordsTheWholeLineYouTyped() throws {
        let bash = try #require(TestShells.path("bash"), TestShells.missing("bash"))
        let directory = try #require(ShellIntegration.directory())
        let rig = try ShellRig(
            shell: .bash, executable: bash, rc: "PS1='$ '\n\(ShellIntegration.bashLine(directory: directory))\n")
        #expect(rig.waitForFirstPrompt())

        #expect(rig.run("echo a; echo b", awaiting: ShellRig.commandEnd))
        #expect(rig.commands().last?.text == "echo a; echo b")
    }

    /// Pressing Enter on an empty line runs nothing, so it must record nothing. It used to
    /// record whatever the first `PROMPT_COMMAND` entry was — one of our own functions, or
    /// your `history -a` — as though you had typed it.
    @Test func bashRecordsNothingForAnEmptyLine() throws {
        let bash = try #require(TestShells.path("bash"), TestShells.missing("bash"))
        let directory = try #require(ShellIntegration.directory())
        let rc = """
            PS1='$ '
            PROMPT_COMMAND='history -a'
            \(ShellIntegration.bashLine(directory: directory))
            """
        let rig = try ShellRig(shell: .bash, executable: bash, rc: rc)
        #expect(rig.waitForFirstPrompt())

        rig.typeAndSettle("")
        rig.typeAndSettle("")
        #expect(rig.run("echo hi", awaiting: ShellRig.commandEnd))
        #expect(rig.commands().map(\.text) == ["echo hi"], "an empty line left a record behind")
    }

    /// `HISTCONTROL=ignorespace` — half of the `ignoreboth` most distributions ship — keeps a
    /// line that starts with a space out of the history. Reading the newest entry anyway put
    /// the *previous* command's text on this one, which is worse than a short answer.
    ///
    /// **And a short answer is now no answer at all.** This test used to assert the text was
    /// `"echo two"`, which looked right — it is not the earlier command — and in doing so
    /// locked in a privacy failure: that is the hidden line, with its leading space eaten by
    /// `$BASH_COMMAND`, so `CommandBests.isPrivate` saw an ordinary command and wrote it to
    /// `bests.json` and into notification banners. A line the user asked to hide now reports
    /// no text, and the two tests below say what that costs and what it protects.
    @Test func bashDoesNotPutAnEarlierCommandsTextOnThisOne() throws {
        let bash = try #require(TestShells.path("bash"), TestShells.missing("bash"))
        let directory = try #require(ShellIntegration.directory())
        let rc = """
            PS1='$ '
            HISTCONTROL=ignoreboth
            \(ShellIntegration.bashLine(directory: directory))
            """
        let rig = try ShellRig(shell: .bash, executable: bash, rc: rc)
        #expect(rig.waitForFirstPrompt())

        #expect(rig.run("echo one", awaiting: ShellRig.commandEnd))
        #expect(rig.run(" echo two", awaiting: ShellRig.commandEnd))
        let text = try #require(rig.commands().last?.text)
        #expect(text != "echo one", "the hidden line was recorded as the command before it")
        #expect(text.isEmpty, "a line the shell was asked to hide must report no text: \(text)")
    }

    /// The record still arrives for a hidden line — the mark, the duration and the exit code —
    /// so the badge and the rail work. It is only the text that is withheld, and withholding it
    /// is what makes every consumer refuse the line: `CommandBests.record` guards on an empty
    /// command, Ring Ring names it "A command", and "Save Last Command to Wishing Well" has
    /// nothing to save.
    @Test func bashStillTimesAHiddenCommand() throws {
        let bash = try #require(TestShells.path("bash"), TestShells.missing("bash"))
        let directory = try #require(ShellIntegration.directory())
        let rc = """
            PS1='$ '
            HISTCONTROL=ignorespace
            \(ShellIntegration.bashLine(directory: directory))
            """
        let rig = try ShellRig(shell: .bash, executable: bash, rc: rc)
        #expect(rig.waitForFirstPrompt())

        #expect(rig.run(" false", awaiting: ShellRig.commandEnd))
        let command = try #require(rig.commands().last)
        #expect(command.text.isEmpty, "the text is the only thing withheld: \(command.text)")
        #expect(command.exitCode == 1, "the exit code still arrives")
        #expect(command.durationMilliseconds != nil, "and so does the duration")
    }

    /// Without `ignorespace` a space-prefixed line *is* in the history, and its leading space
    /// has to survive being read back out of it — the convention is the only signal
    /// `CommandBests.isPrivate` has.
    ///
    /// It did not: `history` prints `%5d%c %s`, and the separator was matched as
    /// `[[:space:]]+`, which is greedy and ate the typed space along with it.
    @Test func bashKeepsTheLeadingSpaceItReadsFromHistory() throws {
        let bash = try #require(TestShells.path("bash"), TestShells.missing("bash"))
        let directory = try #require(ShellIntegration.directory())
        let rc = """
            PS1='$ '
            HISTCONTROL=
            \(ShellIntegration.bashLine(directory: directory))
            """
        let rig = try ShellRig(shell: .bash, executable: bash, rc: rc)
        #expect(rig.waitForFirstPrompt())

        #expect(rig.run(" echo hidden", awaiting: ShellRig.commandEnd))
        let text = try #require(rig.commands().last?.text)
        #expect(text == " echo hidden", "the leading space was eaten: [\(text)]")
        #expect(CommandBests.isPrivate(text), "which is the whole point of keeping it")
    }

    /// `$EPOCHREALTIME` follows `LC_NUMERIC`, so in a German or French locale its decimal
    /// point is a comma — and the arithmetic that split it on `.` turned `sleep 0.3` into
    /// `dur=304037614`. The value is forced here rather than the locale set, because a
    /// container has only the C locale and generating another would be a slower, less direct
    /// way of asking the same question of the same two lines.
    @Test func bashTimesACommandWhenTheDecimalPointIsAComma() throws {
        let bash = try #require(TestShells.path("bash"), TestShells.missing("bash"))
        let directory = try #require(ShellIntegration.directory())
        let rig = try ShellRig(
            shell: .bash, executable: bash, rc: "PS1='$ '\n\(ShellIntegration.bashLine(directory: directory))\n")
        #expect(rig.waitForFirstPrompt())

        // `true &&` first, so the trap sees a command that is not one of ours and still arms:
        // the start time it records is then replaced by the same instant written the German way.
        #expect(
            rig.run(#"true && __deathrace_started="${EPOCHREALTIME%%.*},000000""#, awaiting: ShellRig.commandEnd))
        let duration = try #require(rig.commands().last?.durationMilliseconds)
        #expect(duration < 2_000, "a comma was read as part of the number: dur=\(duration)")
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

    /// The escaper was a pipeline, and `string replace` reading stdin works a line at a time —
    /// so `\n` could never match and a command written across two lines went out with a raw
    /// line break in it, which the engine dropped, running the halves together.
    @Test func fishKeepsTheHalvesOfAMultiLineCommandApart() throws {
        let fish = try #require(TestShells.path("fish"), TestShells.missing("fish"))
        let rig = try ShellRig(shell: .fish, executable: fish, rc: "function fish_prompt\n  echo -n '$ '\nend\n")
        #expect(rig.waitForFirstPrompt())

        #expect(rig.run("echo one; and \\\necho two", awaiting: ShellRig.commandEnd))
        let text = try #require(rig.commands().last?.text)
        #expect(text.contains("echo one"))
        #expect(text.contains("echo two"))
        #expect(!text.contains("\n"))
        #expect(!text.contains("oneecho") && !text.contains("\\echo"), "a line break was dropped: \(text)")
    }

    /// Defining `fish_prompt` at the prompt, or reloading a config, replaces our wrapper
    /// outright. A flag set once said we had already wrapped, so the marks never came back.
    @Test func fishRewrapsAPromptYouRedefineLater() throws {
        let fish = try #require(TestShells.path("fish"), TestShells.missing("fish"))
        let rig = try ShellRig(shell: .fish, executable: fish, rc: "function fish_prompt\n  echo -n '$ '\nend\n")
        #expect(rig.waitForFirstPrompt())

        #expect(rig.run("function fish_prompt; echo -n 'NEW> '; end", awaiting: ShellRig.commandEnd))
        #expect(rig.run("echo after", awaiting: ShellRig.commandEnd))
        let afterward = rig.raw.components(separatedBy: "NEW>").dropFirst().joined()
        #expect(afterward.contains("133;A"), "the prompt you redefined was never marked again")
        #expect(rig.commands().last?.text == "echo after")
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
