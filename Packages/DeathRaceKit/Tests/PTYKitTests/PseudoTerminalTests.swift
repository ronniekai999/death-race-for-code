import Testing

@testable import PTYKit

#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#endif

/// A plain POSIX shell with no rc files, so the tests see only what they typed.
private func shell(_ extraArguments: [String] = []) -> ShellLaunch {
    ShellLaunch(
        executable: "/bin/sh",
        arguments: ["sh"] + extraArguments,
        environment: ShellLaunch.terminalEnvironment(
            inheriting: ["PATH": "/usr/bin:/bin", "PS1": "$ "], appVersion: "test")
    )
}

/// Polls `condition` for up to five seconds; terminal modes change without any output.
private func waitFor(_ condition: () -> Bool) -> Bool {
    let deadline = PseudoTerminal.monotonicMilliseconds() + 5_000
    while !condition() {
        if PseudoTerminal.monotonicMilliseconds() > deadline { return false }
        var pause = timespec(tv_sec: 0, tv_nsec: 10_000_000)
        nanosleep(&pause, nil)
    }
    return true
}

/// `path` with symbolic links resolved (/tmp is /private/tmp on macOS).
private func resolved(_ path: String) -> String {
    guard let real = realpath(path, nil) else { return path }
    defer { free(real) }
    return String(cString: real)
}

@Suite("PseudoTerminal")
struct PseudoTerminalTests {
    @Test("the foreground job and its directory are visible from the master side")
    func foregroundProcess() throws {
        let terminal = try PseudoTerminal.spawn(shell(["-i"]), size: TerminalSize(rows: 24, columns: 80))
        defer { terminal.hangUp() }
        // At its prompt the shell is the foreground.
        #expect(waitFor { terminal.foregroundProcess()?.isShell == true })
        #expect(terminal.foregroundProcess()?.pid == terminal.pid)
        #expect(terminal.foregroundProcess()?.name.isEmpty == false)

        // With job control, a command runs in a process group of its own.
        terminal.writeAll("cd /tmp && sleep 5\n")
        #expect(waitFor { terminal.foregroundProcess()?.name == "sleep" })
        let job = terminal.foregroundProcess()
        #expect(job?.isShell == false)
        #expect(job?.pid != terminal.pid)
        #expect(job?.workingDirectory == resolved("/tmp"))
    }

    @Test("process names and directories, and nothing for a process that does not exist")
    func processLookups() {
        #expect(PseudoTerminal.processName(getpid())?.isEmpty == false)
        #expect(PseudoTerminal.workingDirectory(of: getpid())?.hasPrefix("/") == true)
        #expect(PseudoTerminal.processName(Int32.max) == nil)
        #expect(PseudoTerminal.workingDirectory(of: Int32.max) == nil)
    }

    @Test("a shell runs a command typed into the terminal")
    func shellRunsTypedCommand() throws {
        let transcript = try SmokeTest.run(shell())
        #expect(transcript.contains("999"))
    }

    @Test("a resize reaches the program on the terminal")
    func resizeReachesChild() throws {
        let terminal = try PseudoTerminal.spawn(shell(), size: TerminalSize(rows: 24, columns: 80))
        defer { terminal.hangUp() }

        try terminal.resize(TerminalSize(rows: 40, columns: 120))
        #expect(terminal.reportedSize?.rows == 40)
        #expect(terminal.reportedSize?.columns == 120)

        terminal.writeAll("stty size\n")
        var transcript: [UInt8] = []
        #expect(
            SmokeTest.readUntil(terminal, contains: Array("40 120".utf8), into: &transcript, timeoutMilliseconds: 5_000)
        )
    }

    @Test("a password prompt is visible from the master side")
    func passwordDetection() throws {
        let terminal = try PseudoTerminal.spawn(shell(), size: TerminalSize(rows: 24, columns: 80))
        defer { terminal.hangUp() }

        #expect(!terminal.isReadingPassword)
        // `read` after `stty -echo` reads a line with echo off, as getpass does.
        terminal.writeAll("stty -echo; echo ready-$((1+1)); read secret; stty echo\n")
        var transcript: [UInt8] = []
        #expect(
            SmokeTest.readUntil(
                terminal, contains: Array("ready-2".utf8), into: &transcript, timeoutMilliseconds: 5_000))
        #expect(waitFor { terminal.isReadingPassword })
        terminal.writeAll("hunter2\n")
        #expect(waitFor { !terminal.isReadingPassword })
    }

    @Test("the exit status of the child is reported")
    func exitStatus() throws {
        let terminal = try PseudoTerminal.spawn(shell(["-c", "exit 3"]), size: TerminalSize(rows: 24, columns: 80))
        var transcript: [UInt8] = []
        _ = SmokeTest.readUntil(terminal, contains: Array("never".utf8), into: &transcript, timeoutMilliseconds: 5_000)
        #expect(terminal.waitForExit(timeoutMilliseconds: 5_000) == .exited(code: 3))
    }

    @Test("a missing executable exits with 127")
    func missingExecutable() throws {
        let launch = ShellLaunch(executable: "/nonexistent/shell", arguments: ["nope"], environment: [:])
        let terminal = try PseudoTerminal.spawn(launch, size: TerminalSize(rows: 24, columns: 80))
        #expect(terminal.waitForExit(timeoutMilliseconds: 5_000) == .exited(code: 127))
    }

    @Test("hanging up ends a shell that printed output nobody read")
    func hangUpWithUnreadOutput() throws {
        // The shell prints a prompt and more that is never read. On macOS its exit then
        // waits for the master to drain that output, so the master must close first.
        let terminal = try PseudoTerminal.spawn(shell(), size: TerminalSize(rows: 24, columns: 80))
        terminal.writeAll("i=0; while [ $i -lt 200 ]; do echo line $i; i=$((i+1)); done\n")
        var pause = timespec(tv_sec: 0, tv_nsec: 200_000_000)
        nanosleep(&pause, nil)
        let status = terminal.hangUp(graceMilliseconds: 3_000)
        #expect(status != nil)
        #expect(terminal.reap() == status)
    }

    @Test("a child that ignores the hangup is killed")
    func hangUpEscalates() throws {
        let launch = ShellLaunch(
            executable: "/bin/sh", arguments: ["sh", "-c", "trap '' HUP; while :; do sleep 1; done"],
            environment: ["PATH": "/usr/bin:/bin"])
        let terminal = try PseudoTerminal.spawn(launch, size: TerminalSize(rows: 24, columns: 80))
        var pause = timespec(tv_sec: 0, tv_nsec: 200_000_000)
        nanosleep(&pause, nil)
        #expect(terminal.hangUp(graceMilliseconds: 500) == .signaled(signal: SIGKILL))
    }
}

@Suite("ShellLaunch")
struct ShellLaunchTests {
    @Test("the environment identifies the terminal without a custom TERM")
    func environment() {
        let env = ShellLaunch.terminalEnvironment(
            inheriting: ["TERM": "dumb", "ITERM_SESSION_ID": "x", "HOME": "/home/legend"],
            appVersion: "9.9.9"
        )
        #expect(env["TERM"] == "xterm-256color")
        #expect(env["COLORTERM"] == "truecolor")
        #expect(env["TERM_PROGRAM"] == "DeathRace")
        #expect(env["TERM_PROGRAM_VERSION"] == "9.9.9")
        #expect(env["LANG"] == "en_US.UTF-8")
        #expect(env["ITERM_SESSION_ID"] == nil)
        #expect(env["HOME"] == "/home/legend")
    }

    @Test("a login shell is started with a dash-prefixed argv[0]")
    func loginShellArgv0() {
        let launch = ShellLaunch.loginShell(inheriting: ["SHELL": "/bin/sh", "HOME": "/tmp"])
        #expect(launch.executable == "/bin/sh")
        #expect(launch.arguments == ["-sh"])
        #expect(launch.workingDirectory == "/tmp")
    }
}
