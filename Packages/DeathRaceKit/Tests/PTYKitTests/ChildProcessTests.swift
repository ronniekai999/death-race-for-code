import CPTY
import Testing

@testable import PTYKit

#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#endif

private let environment = ["PATH": "/usr/bin:/bin"]

private func sh(_ script: String, input: [UInt8] = [], timeout: Int = 5_000) throws -> ChildResult {
    try ChildProcess.run(
        executable: "/bin/sh", arguments: ["sh", "-c", script], environment: environment, input: input,
        timeoutMilliseconds: timeout)
}

@Suite("ChildProcess")
struct ChildProcessTests {
    @Test func outputErrorsAndStatusComeBackApart() throws {
        let result = try sh("echo out; echo err >&2; exit 3")
        #expect(result.outputText == "out\n")
        #expect(result.errorText == "err\n")
        #expect(result.status == .exited(code: 3))
        #expect(!result.timedOut)
        #expect(!result.succeeded)
    }

    @Test func inputIsWrittenThenClosed() throws {
        let result = try ChildProcess.run(
            executable: "/bin/cat", arguments: ["cat"], environment: environment, input: Array("from the app\n".utf8))
        #expect(result.outputText == "from the app\n")
        #expect(result.succeeded)
    }

    @Test func aLongInputAndALongOutputDontDeadlock() throws {
        // More than any pipe holds, both ways at once.
        let input = [UInt8](repeating: UInt8(ascii: "x"), count: 1 << 20)
        let result = try ChildProcess.run(
            executable: "/bin/cat", arguments: ["cat"], environment: environment, input: input)
        #expect(result.output.count == input.count)
        #expect(result.succeeded)
    }

    @Test func aProgramThatStopsReadingEndsItsInputWithoutSIGPIPE() throws {
        // `true` exits without reading: the write must fail with EPIPE, not kill the tests.
        let input = [UInt8](repeating: 0, count: 1 << 20)
        let result = try ChildProcess.run(
            executable: "/bin/sh", arguments: ["sh", "-c", "exit 0"], environment: environment, input: input)
        #expect(result.status == .exited(code: 0))
    }

    @Test func aProgramPastItsTimeIsEndedWithItsGroup() throws {
        let started = PseudoTerminal.monotonicMilliseconds()
        let result = try sh("sleep 30 & sleep 30", timeout: 300)
        #expect(result.timedOut)
        #expect(result.status == .signaled(signal: SIGTERM))
        #expect(PseudoTerminal.monotonicMilliseconds() - started < 5_000)
    }

    @Test func aGrandchildHoldingThePipesDoesntHoldUpTheResult() throws {
        // The shell exits at once; its background sleep keeps stdout open.
        let started = PseudoTerminal.monotonicMilliseconds()
        let result = try sh("sleep 3 & echo done", timeout: 10_000)
        #expect(result.outputText == "done\n")
        #expect(result.status == .exited(code: 0))
        #expect(!result.timedOut)
        #expect(PseudoTerminal.monotonicMilliseconds() - started < 2_500)
    }

    @Test func itLeadsASessionOfItsOwnAsSoonAsSpawnReturns() throws {
        // Spawning waits for the child's exec, so its group can be signalled at once. Without
        // that wait, a check straight after fork() loses the race now and then.
        for _ in 0..<20 {
            let child = try ChildProcess.spawn(
                executable: "/bin/sleep", arguments: ["sleep", "5"], environment: environment)
            defer {
                child.signal(SIGKILL)
                _ = child.waitForExit(timeoutMilliseconds: 2_000)
            }
            #expect(child.isSessionLeader)
            #expect(getsid(child.pid) == child.pid)
            #expect(getpgid(child.pid) == child.pid)
        }
    }

    @Test func aMissingProgramExits127() throws {
        let result = try ChildProcess.run(
            executable: "/nonexistent/program", arguments: ["program"], environment: environment)
        #expect(result.status == .exited(code: 127))
    }

    @Test func theWorkingDirectoryIsSet() throws {
        let result = try ChildProcess.run(
            executable: "/bin/sh", arguments: ["sh", "-c", "pwd"], environment: environment, workingDirectory: "/")
        #expect(result.outputText == "/\n")
    }

    @Test func outputPastTheLimitIsDropped() throws {
        let result = try ChildProcess.run(
            executable: "/bin/sh", arguments: ["sh", "-c", "yes | head -c 100000"], environment: environment,
            outputLimit: 1_000)
        #expect(result.output.count == 1_000)
        #expect(result.succeeded)
    }
}

@Suite("Process lookups")
struct ProcessLookupTests {
    @Test func theOtherEndOfASocketIsThisProcess() throws {
        var fds: [Int32] = [-1, -1]
        #if canImport(Darwin)
            let kind = SOCK_STREAM
        #else
            let kind = Int32(SOCK_STREAM.rawValue)
        #endif
        #expect(socketpair(AF_UNIX, kind, 0, &fds) == 0)
        defer {
            close(fds[0])
            close(fds[1])
        }
        var pid: pid_t = 0
        var uid: uid_t = 0
        #expect(cpty_peer_credentials(fds[0], &pid, &uid) == 0)
        #expect(pid == getpid())
        #expect(uid == getuid())
    }

    @Test func aProcessKnowsItsParent() {
        #expect(cpty_parent_pid(getpid()) == getppid())
        #expect(cpty_parent_pid(-1) == -1)
    }
}
