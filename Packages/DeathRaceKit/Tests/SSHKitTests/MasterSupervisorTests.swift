import Foundation
import PTYKit
import Synchronization
import Testing
import Vault

@testable import SSHKit

#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#endif

/// Ends `master` if it hasn't settled within `seconds`, so a hung ssh fails the test instead
/// of the whole run.
func settle(_ master: MasterSupervisor, within seconds: Int = 30) async -> MasterSupervisor.State {
    let watchdog = Task {
        try? await Task.sleep(for: .seconds(seconds))
        if !Task.isCancelled { master.end(.failed(.other("The test gave up waiting."))) }
    }
    defer { watchdog.cancel() }
    return await master.settled()
}

func ending(of master: MasterSupervisor, within seconds: Int = 30) async -> MasterSupervisor.Ending {
    let watchdog = Task {
        try? await Task.sleep(for: .seconds(seconds))
        if !Task.isCancelled { master.end(.failed(.other("The test gave up waiting."))) }
    }
    defer { watchdog.cancel() }
    return await master.ending()
}

/// A process still running (a zombie counts as gone).
func isRunning(_ pid: Int32) -> Bool {
    guard kill(pid, 0) == 0 else { return false }
    #if os(Linux)
        let stat = (try? String(contentsOfFile: "/proc/\(pid)/stat", encoding: .utf8)) ?? ""
        if let close = stat.lastIndex(of: ")") {
            return !stat[close...].hasPrefix(") Z")
        }
    #endif
    return true
}

@Suite("ssh masters, without a server")
struct MasterSupervisorTests {
    let folder: String
    let paths: WRLDPaths

    init() throws {
        folder = try shortTemporaryFolder()
        paths = WRLDPaths(root: folder + "/dr")
        try FileManager.default.createDirectory(atPath: paths.controlFolder, withIntermediateDirectories: true)
    }

    /// A config for `hosts`, with `user` as the included "user config".
    func config(_ hosts: [WRLDHost], user: String = "") throws -> GeneratedConfig {
        let include = folder + "/user_config"
        try user.write(toFile: include, atomically: true, encoding: .utf8)
        let config = GeneratedConfig(vault: Vault(hosts: hosts), paths: paths, includes: [include])
        try config.text.write(toFile: paths.generatedConfig, atomically: true, encoding: .utf8)
        return config
    }

    func master(_ id: HostID, in config: GeneratedConfig, states: StateLog? = nil) throws -> MasterSupervisor {
        let alias = try #require(config.aliases[id])
        let controlPath = try #require(config.controlPaths[id])
        return MasterSupervisor(
            alias: alias, config: paths.generatedConfig, controlPath: controlPath,
            environment: ["PATH": "/usr/bin:/bin", "SSH_ASKPASS_REQUIRE": "never"],
            onChange: { states?.add($0) })
    }

    @Test(.enabled(if: RealSSH.shouldRun)) func nothingListeningEndsAsRefused() async throws {
        defer { try? FileManager.default.removeItem(atPath: folder) }
        let id = HostID(rawValue: "h1")
        let closed = WRLDHost(id: id, name: "closed", source: .wrld(Connection(address: "127.0.0.1", port: 1)))
        let config = try config([closed])
        let states = StateLog()
        let master = try master(id, in: config, states: states)
        try master.start()
        #expect(await settle(master) == .ended(.failed(.refused)))
        #expect(states.all == [.ended(.failed(.refused))])
        #expect(!FileManager.default.fileExists(atPath: master.controlPath))
    }

    @Test(.enabled(if: RealSSH.shouldRun)) func endingTakesItsProxyCommandWithIt() async throws {
        defer { try? FileManager.default.removeItem(atPath: folder) }
        // A host from your ~/.ssh/config whose ProxyCommand never answers.
        let pidFile = folder + "/proxy.pid"
        let id = HostID(rawValue: "h1")
        let config = try config(
            [WRLDHost(id: id, name: "stuck", source: .sshConfig(alias: "stuck"))],
            user: """
                Host stuck
                    ProxyCommand /bin/sh -c 'echo $$ > \(pidFile); exec /bin/sleep 60'
                """)
        let master = try master(id, in: config)
        let pid = try master.start()
        #expect(await eventually { FileManager.default.fileExists(atPath: pidFile) })
        let proxy = try #require(
            Int32(String(contentsOfFile: pidFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
        #expect(master.state == .connecting)
        #expect(master.pid == pid)

        master.end()
        #expect(await ending(of: master) == .closed)
        #expect(await eventually { !isRunning(proxy) })
        #expect(!isRunning(pid))
    }

    @Test(.enabled(if: RealSSH.shouldRun)) func cancellingSaysCancelled() async throws {
        defer { try? FileManager.default.removeItem(atPath: folder) }
        let id = HostID(rawValue: "h1")
        let config = try config(
            [WRLDHost(id: id, name: "stuck", source: .sshConfig(alias: "stuck"))],
            user: "Host stuck\n    ProxyCommand /bin/sleep 60\n")
        let master = try master(id, in: config)
        try master.start()
        master.end(.failed(.cancelled))
        master.end(.closed)
        #expect(await ending(of: master) == .failed(.cancelled))
    }

    @Test(.enabled(if: RealSSH.shouldRun)) func endingBeforeStartingStillEndsIt() async throws {
        defer { try? FileManager.default.removeItem(atPath: folder) }
        let id = HostID(rawValue: "h1")
        let config = try config(
            [WRLDHost(id: id, name: "stuck", source: .sshConfig(alias: "stuck"))],
            user: "Host stuck\n    ProxyCommand /bin/sleep 60\n")
        let master = try master(id, in: config)
        master.end(.failed(.cancelled))
        let started = UnixSocket.monotonicMilliseconds()
        try master.start()
        #expect(await ending(of: master) == .failed(.cancelled))
        #expect(UnixSocket.monotonicMilliseconds() - started < 10_000)
    }

    @Test(.enabled(if: RealSSH.shouldRun)) func aMasterAlreadyListeningIsntReplaced() throws {
        defer { try? FileManager.default.removeItem(atPath: folder) }
        let id = HostID(rawValue: "h1")
        let config = try config([WRLDHost(id: id, name: "closed", source: .wrld(Connection(address: "127.0.0.1")))])
        let master = try master(id, in: config)
        let listener = try UnixSocket.listen(at: master.controlPath)
        defer { close(listener) }
        #expect(throws: MasterSupervisor.Failure.alreadyRunning(master.controlPath)) { try master.start() }
    }

    @Test(.enabled(if: RealSSH.shouldRun)) func aDeadSocketLeftBehindIsCleared() async throws {
        defer { try? FileManager.default.removeItem(atPath: folder) }
        let id = HostID(rawValue: "h1")
        let config = try config(
            [WRLDHost(id: id, name: "closed", source: .wrld(Connection(address: "127.0.0.1", port: 1)))])
        let master = try master(id, in: config)
        // A socket nothing listens on: what a master killed with SIGKILL leaves.
        close(try UnixSocket.listen(at: master.controlPath))
        #expect(FileManager.default.fileExists(atPath: master.controlPath))
        try master.start()
        #expect(await settle(master) == .ended(.failed(.refused)))
    }

    @Test(.enabled(if: RealSSH.shouldRun)) func aPoolConnectionStuckConnectingCanBeCancelled() async throws {
        defer { try? FileManager.default.removeItem(atPath: folder) }
        let helper = try #require(BuiltHelper.path, BuiltHelper.missing)
        let id = HostID(rawValue: "h1")
        let config = try config(
            [WRLDHost(id: id, name: "stuck", source: .sshConfig(alias: "stuck"))],
            user: "Host stuck\n    ProxyCommand /bin/sleep 60\n")
        let broker = AskpassBroker(
            socketPath: folder + "/askpass.sock", secrets: MemorySecretStore(), presence: ScriptedPresence(),
            presenter: ScriptedPresenter())
        try broker.start()
        defer { broker.stop() }
        let pool = MasterPool(
            broker: broker,
            settings: MasterPool.Settings(
                config: paths.generatedConfig, helper: helper, environment: ["PATH": "/usr/bin:/bin"]))
        let target = ConnectionTarget(
            key: "alias:stuck", alias: "stuck", controlPath: try #require(config.controlPaths[id]), name: "stuck")
        let connecting = Task { await pool.connect(target, for: "pane-1") }
        #expect(await eventually { pool.master(for: "alias:stuck")?.state == .connecting })
        #expect(pool.connected.isEmpty)
        pool.cancel("alias:stuck")
        #expect(await connecting.value == .failed(.cancelled))
        #expect(pool.master(for: "alias:stuck") == nil)

        // The pane that asked closing while it connects stops it too.
        let abandoned = Task { await pool.connect(target, for: "pane-2") }
        #expect(await eventually { pool.master(for: "alias:stuck")?.pid != nil })
        pool.release("pane-2")
        #expect(await abandoned.value == .failed(.cancelled))
    }

    @Test func leftoverCleanupTouchesOnlyControlSockets() async throws {
        defer { try? FileManager.default.removeItem(atPath: folder) }
        let dead = paths.controlPath(for: "h-dead")
        close(try UnixSocket.listen(at: dead))
        let notASocket = paths.controlFolder + "/0123456789abcdef"
        try "x".write(toFile: notASocket, atomically: true, encoding: .utf8)
        let otherName = paths.controlFolder + "/mine.sock"
        close(try UnixSocket.listen(at: otherName))

        let ended = await MasterSupervisor.cleanUpLeftovers(
            in: paths.controlFolder, runner: SystemProcessRunner(), environment: ["PATH": "/usr/bin:/bin"])
        #expect(ended == 0)
        #expect(!FileManager.default.fileExists(atPath: dead))
        #expect(FileManager.default.fileExists(atPath: notASocket))
        #expect(FileManager.default.fileExists(atPath: otherName))
    }

    @Test func anExitWithNothingSaidStillHasAReason() {
        #expect(MasterSupervisor.failure(for: .exited(code: 0)) == .closedByRemote)
        #expect(MasterSupervisor.failure(for: .exited(code: 255)) == .other("ssh exited with status 255."))
        #expect(MasterSupervisor.failure(for: .signaled(signal: 9)) == .other("ssh was ended by signal 9."))
    }

    @Test func linesFromBeforeTheConnectionDontExplainItsEnd() {
        var log = MasterLog()
        log.append("Warning: Permanently added '[127.0.0.1]:2222' (ED25519) to the list of known hosts.\n")
        #expect(log.lines.isEmpty)
        log.append("Some banner the server sent\n")
        log.append("** WARNING: connection is not using a post-quantum key exchange algorithm.\n")
        #expect(log.warnsPostQuantum)
        log.connected()
        #expect(log.lines.isEmpty)
        #expect(log.warnsPostQuantum)
        #expect(log.failure == nil)
    }
}

/// Every state a master reported, in order.
final class StateLog: Sendable {
    private let states = Mutex<[MasterSupervisor.State]>([])

    func add(_ state: MasterSupervisor.State) { states.withLock { $0.append(state) } }
    var all: [MasterSupervisor.State] { states.withLock { $0 } }
}

@Suite("Your login shell's environment")
struct LoginEnvironmentTests {
    @Test func pathAndAgentComeFromTheStartupFiles() async throws {
        let home = try shortTemporaryFolder()
        defer { try? FileManager.default.removeItem(atPath: home) }
        try """
        echo "Welcome to the WRLD"
        export PATH="/opt/wrld/bin:$PATH"
        export SSH_AUTH_SOCK=/tmp/wrld-agent.sock
        export UNRELATED=1
        """.write(toFile: home + "/.bash_profile", atomically: true, encoding: .utf8)
        let found = await LoginEnvironment.read(
            shell: "/bin/bash", environment: ["HOME": home, "PATH": "/usr/bin:/bin"])
        // System startup files (path_helper on macOS, /etc/profile.d) add to PATH too.
        #expect(found.keys.sorted() == ["PATH", "SSH_AUTH_SOCK"])
        #expect(found["PATH"]?.hasPrefix("/opt/wrld/bin:") == true)
        #expect(found["SSH_AUTH_SOCK"] == "/tmp/wrld-agent.sock")
    }

    @Test func aShellThatHangsOrIsMissingGivesNothing() async throws {
        let home = try shortTemporaryFolder()
        defer { try? FileManager.default.removeItem(atPath: home) }
        try "/bin/sleep 30\n".write(toFile: home + "/.bash_profile", atomically: true, encoding: .utf8)
        let hung = await LoginEnvironment.read(
            shell: "/bin/bash", environment: ["HOME": home, "PATH": "/usr/bin:/bin"], timeoutMilliseconds: 500)
        #expect(hung.isEmpty)
        let missing = await LoginEnvironment.read(shell: "/nonexistent/shell", environment: ["HOME": home])
        #expect(missing.isEmpty)
    }

    @Test func onlyWhatIsBetweenTheMarkersCounts() {
        let output = """
            PATH=/before
            M
            PATH=/a:/b
            SSH_AUTH_SOCK=
            TERM=dumb
            M
            SSH_AUTH_SOCK=/after
            """
        #expect(LoginEnvironment.parse(output, marker: "M") == ["PATH": "/a:/b"])
        #expect(LoginEnvironment.parse("PATH=/x\n", marker: "M").isEmpty)
        #expect(LoginEnvironment.parse("M\r\nPATH=/a\r\nM\r\n", marker: "M") == ["PATH": "/a"])
        #expect(
            LoginEnvironment.merging(["PATH": "/login"], into: ["PATH": "/app", "HOME": "/h"])
                == ["PATH": "/login", "HOME": "/h"])
    }

    @Test func theCommandRunsInAnyShell() {
        let command = LoginEnvironment.command(shell: "/opt/homebrew/bin/fish", marker: "M")
        #expect(
            command == [
                "/opt/homebrew/bin/fish", "-l", "-i", "-c",
                "/usr/bin/printf '\\n%s\\n' M; /usr/bin/env; /usr/bin/printf '\\n%s\\n' M",
            ])
    }

    @Test func askpassVariablesGoOnTop() {
        let environment = AskpassEnvironment.adding(
            helper: "/A/deathrace-askpass", socket: "/run/a.sock", token: "t", to: ["PATH": "/usr/bin"])
        #expect(
            environment == [
                "PATH": "/usr/bin", "SSH_ASKPASS": "/A/deathrace-askpass", "SSH_ASKPASS_REQUIRE": "force",
                "DEATHRACE_ASKPASS_SOCKET": "/run/a.sock", "DEATHRACE_ASKPASS_TOKEN": "t",
            ])
    }
}

@Suite("Tunnel requests")
struct TunnelControllerTests {
    @Test func whatSSHSaidWhenItFailed() {
        #expect(
            TunnelController.failure(
                from: "Control socket connect(/x/cm/abc): No such file or directory\n") == .noConnection)
        #expect(
            TunnelController.failure(
                from:
                    "mux_client_forward: forwarding request failed: remote port forwarding failed for listen port 9000\n"
            )
                == .refused(
                    "mux_client_forward: forwarding request failed: remote port forwarding failed for listen port 9000")
        )
        #expect(TunnelController.failure(from: "") == .other("ssh couldn't change the tunnel."))
        #expect(TunnelController.Failure.portInUse(5432).sentence == "Port 5432 is in use on this Mac.")
    }

    @Test func aPortSomethingListensOnIsntFree() throws {
        let fd = socket(AF_INET, Int32(streamSocketType), 0)
        defer { close(fd) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { pointer -> Bool in
                bind(fd, pointer, length) == 0 && listen(fd, 1) == 0 && getsockname(fd, pointer, &length) == 0
            }
        }
        try #require(bound)
        let port = Int(UInt16(bigEndian: address.sin_port))
        #expect(!TunnelController.isFree(port: port, address: nil))
        #expect(!TunnelController.isFree(port: port, address: "localhost"))
        #expect(!TunnelController.isFree(port: port, address: "127.0.0.1"))
        // Names other than localhost are left to ssh.
        #expect(TunnelController.isFree(port: port, address: "db.internal"))
    }
}

#if canImport(Darwin)
    let streamSocketType = SOCK_STREAM
#else
    let streamSocketType = Int32(SOCK_STREAM.rawValue)
#endif
