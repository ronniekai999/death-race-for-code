import Foundation
import PTYKit
import Testing
import Vault

@testable import SSHKit

#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#endif

/// The throwaway sshd `scripts/ci-sshd.sh` starts, on two loopback addresses: one plays a
/// jump host, the other a host behind it. Without `DEATHRACE_SSHD` these tests are skipped.
enum TestSSHD {
    static let environment = ProcessInfo.processInfo.environment
    static let isAvailable = !(environment["DEATHRACE_SSHD"] ?? "").isEmpty

    static func endpoint(_ name: String) -> (address: String, port: Int) {
        let value = environment[name] ?? ""
        guard let colon = value.lastIndex(of: ":") else { return (value, 22) }
        return (String(value[..<colon]), Int(value[value.index(after: colon)...]) ?? 22)
    }

    static let jump = endpoint("DEATHRACE_SSHD")
    static let target = endpoint("DEATHRACE_SSHD_TARGET")
    static let jumpUser = environment["DEATHRACE_SSHD_JUMP_USER"] ?? ""
    static let jumpPassword = environment["DEATHRACE_SSHD_JUMP_PASSWORD"] ?? ""
    static let targetUser = environment["DEATHRACE_SSHD_TARGET_USER"] ?? ""
    static let targetPassword = environment["DEATHRACE_SSHD_TARGET_PASSWORD"] ?? ""
}

/// A master's broker registration, which needs the master to cancel and the master needs
/// its token first.
private final class LateMaster: Sendable {
    private let master = Locked<MasterSupervisor?>(nil)

    func set(_ value: MasterSupervisor) { master.withLock { $0 = value } }
    func end(_ ending: MasterSupervisor.Ending) { master.withLock { $0 }?.end(ending) }
}

/// WRLD with a jump host and a target behind it, the config it compiles to, and a broker
/// with test doubles for the Keychain, Touch ID and sheets, in a folder of its own. Masters
/// are wired to the broker as the app wires them.
private final class Rig: Sendable {
    static let jumpID = HostID(rawValue: "h-jump")
    static let targetID = HostID(rawValue: "h-target")
    static let closedID = HostID(rawValue: "h-closed")
    static let jumpRef = SecretRef(.hostPassword, "h-jump")
    static let targetRef = SecretRef(.hostPassword, "h-target")
    static let jumpHop = AskpassPrompt.Hop(user: TestSSHD.jumpUser, host: TestSSHD.jump.address)
    static let targetHop = AskpassPrompt.Hop(user: TestSSHD.targetUser, host: TestSSHD.target.address)

    let folder: String
    let paths: WRLDPaths
    let config: GeneratedConfig
    let helper: String
    let secrets: MemorySecretStore
    let presence: ScriptedPresence
    let presenter: ScriptedPresenter
    let broker: AskpassBroker
    private let masters = Locked<[MasterSupervisor]>([])

    /// `settings` go first in the included user config, so they win over the defaults
    /// after them.
    init(
        settings: [String] = [], saved: [SecretRef: String] = [:], touchID: Bool = true,
        answers: [PromptAnswer] = []
    ) throws {
        helper = try #require(BuiltHelper.path, BuiltHelper.missing)
        folder = try shortTemporaryFolder()
        paths = WRLDPaths(root: folder + "/dr")
        let user = folder + "/user_config"
        let lines =
            settings + [
                "UserKnownHostsFile \(folder)/known_hosts", "GlobalKnownHostsFile /dev/null",
                "StrictHostKeyChecking accept-new", "PubkeyAuthentication no", "IdentityAgent none",
                "NumberOfPasswordPrompts 2", "ConnectTimeout 10",
            ]
        try ("Host *\n" + lines.map { "    \($0)\n" }.joined()).write(toFile: user, atomically: true, encoding: .utf8)
        let hosts = [
            WRLDHost(
                id: Self.jumpID, name: "jump",
                source: .wrld(
                    Connection(address: TestSSHD.jump.address, user: TestSSHD.jumpUser, port: TestSSHD.jump.port))),
            WRLDHost(
                id: Self.targetID, name: "target",
                source: .wrld(
                    Connection(
                        address: TestSSHD.target.address, user: TestSSHD.targetUser, port: TestSSHD.target.port,
                        jumpHostID: Self.jumpID))),
            WRLDHost(id: Self.closedID, name: "closed", source: .wrld(Connection(address: "127.0.0.1", port: 1))),
        ]
        config = GeneratedConfig(vault: Vault(hosts: hosts), paths: paths, includes: [user])
        try FileManager.default.createDirectory(atPath: paths.root, withIntermediateDirectories: true)
        try config.text.write(toFile: paths.generatedConfig, atomically: true, encoding: .utf8)
        secrets = MemorySecretStore(saved)
        presence = ScriptedPresence(allows: touchID)
        presenter = ScriptedPresenter(answers)
        broker = AskpassBroker(
            socketPath: folder + "/askpass.sock", secrets: secrets, presence: presence, presenter: presenter)
        try broker.start()
    }

    /// Starts a master for `host`, registered with the broker: a cancel ends it, connecting
    /// saves what you asked to remember, and ending forgets the token.
    func master(_ host: HostID, mayAsk: Bool = true) async throws -> MasterSupervisor {
        let late = LateMaster()
        // The hops as ssh will name them, worked out as the app works them out.
        let alias = try #require(config.aliases[host])
        let chain = try await HostChain.resolve(
            alias: alias, config: paths.generatedConfig, runner: SystemProcessRunner(),
            environment: ["PATH": "/usr/bin:/bin"])
        let names = Dictionary(uniqueKeysWithValues: config.aliases.map { ($0.value, $0.key) })
        let context = chain.askpassContext(hostName: host == Self.targetID ? "target" : "jump", mayAsk: mayAsk) {
            guard let id = names[$0] else { return nil }
            return (SecretRef(.hostPassword, id.rawValue), id == Self.targetID ? "target" : "jump")
        }
        let token = broker.register(context) { late.end(.failed(.cancelled)) }
        let environment = AskpassEnvironment.adding(
            helper: helper, socket: broker.socketPath, token: token, to: ["PATH": "/usr/bin:/bin", "HOME": folder])
        let master = MasterSupervisor(
            alias: alias, config: paths.generatedConfig,
            controlPath: try #require(config.controlPaths[host]), environment: environment
        ) { [broker] state in
            switch state {
            case .ready: broker.connected(token: token)
            case .ended: broker.unregister(token: token)
            case .connecting: break
            }
        }
        late.set(master)
        masters.withLock { $0.append(master) }
        let pid = try master.start()
        broker.attach(token: token, rootPID: pid)
        return master
    }

    /// What a pane runs, through `host`'s master. BatchMode: it can't log in by itself.
    func run(on host: HostID, _ command: String) async throws -> ChildResult {
        let alias = try #require(config.aliases[host])
        return try await SystemProcessRunner().run(
            Command(
                SSHCommand.remote(alias: alias, config: paths.generatedConfig, command: command),
                environment: ["PATH": "/usr/bin:/bin"]))
    }

    /// Each host's WRLD name.
    static func name(_ host: HostID) -> String {
        switch host {
        case targetID: "target"
        case closedID: "closed"
        default: "jump"
        }
    }

    /// How the app's pool sees a host.
    func target(_ host: HostID) throws -> ConnectionTarget {
        ConnectionTarget(
            key: host.rawValue, alias: try #require(config.aliases[host]),
            controlPath: try #require(config.controlPaths[host]), name: Self.name(host))
    }

    /// WRLD's passwords, by alias, as the app hands them to the pool.
    var saved: [String: SavedSecret] {
        Dictionary(
            uniqueKeysWithValues: config.aliases.map { id, alias in
                (
                    alias,
                    SavedSecret(ref: SecretRef(.hostPassword, id.rawValue), name: Self.name(id))
                )
            })
    }

    func pool(idleClose: Duration = .seconds(600), endings: EndingLog? = nil) throws -> MasterPool {
        MasterPool(
            broker: broker,
            settings: MasterPool.Settings(
                config: paths.generatedConfig, helper: helper, environment: ["PATH": "/usr/bin:/bin", "HOME": folder],
                idleClose: idleClose),
            onEnd: { key, ending in endings?.add(key, ending) })
    }

    var tunnels: TunnelController {
        TunnelController(runner: SystemProcessRunner(), environment: ["PATH": "/usr/bin:/bin"])
    }

    /// Ends every master and removes the folder.
    func finish() async {
        for master in masters.withLock({ $0 }) {
            master.end()
            _ = await ending(of: master)
        }
        broker.stop()
        try? FileManager.default.removeItem(atPath: folder)
    }
}

@Suite("Against a real sshd", .serialized, .enabled(if: TestSSHD.isAvailable))
struct SSHDTests {
    // MARK: - Logging in

    @Test func aPasswordAndANewHostKeyAreAskedThroughTheBroker() async throws {
        let rig = try Rig(
            settings: ["StrictHostKeyChecking ask", "PreferredAuthentications password"],
            answers: [.yes, .text(TestSSHD.jumpPassword, remember: true)])
        let master = try await rig.master(Rig.jumpID)
        await expectReady(master)

        let questions = rig.presenter.questions
        try #require(questions.count == 2)
        guard case .newHostKey(let host, let keyType, let fingerprint) = questions[0].prompt.kind else {
            Issue.record("Not a host key question: \(questions[0].prompt.text)")
            await rig.finish()
            return
        }
        #expect(host == "[\(TestSSHD.jump.address)]:\(TestSSHD.jump.port)")
        #expect(keyType == "ED25519")
        #expect(fingerprint?.hasPrefix("SHA256:") == true)
        #expect(questions[1].prompt.kind == .password(Rig.jumpHop))
        #expect(questions[1].canRemember)
        #expect(try await rig.secrets.read(Rig.jumpRef) == TestSSHD.jumpPassword)
        let knownHosts = try String(contentsOfFile: rig.folder + "/known_hosts", encoding: .utf8)
        #expect(knownHosts.contains("[\(TestSSHD.jump.address)]:\(TestSSHD.jump.port)"))

        let whoami = try await rig.run(on: Rig.jumpID, "whoami")
        #expect(whoami.outputText == TestSSHD.jumpUser + "\n", "\(whoami.errorText)")

        master.end()
        #expect(await ending(of: master) == .closed)
        #expect(!FileManager.default.fileExists(atPath: master.controlPath))
        await rig.finish()
    }

    @Test func aSavedPasswordTakesOnlyTouchID() async throws {
        let rig = try Rig(saved: [Rig.jumpRef: TestSSHD.jumpPassword])
        let master = try await rig.master(Rig.jumpID)
        await expectReady(master)
        #expect(rig.presence.reasons == ["use the saved password for jump"])
        #expect(rig.presenter.questions.isEmpty)
        await rig.finish()
    }

    @Test func throughAJumpHostEachHopGetsItsOwnPassword() async throws {
        let rig = try Rig(saved: [Rig.jumpRef: TestSSHD.jumpPassword, Rig.targetRef: TestSSHD.targetPassword])
        let master = try await rig.master(Rig.targetID)
        await expectReady(master)
        #expect(
            rig.presence.reasons.sorted() == ["use the saved password for jump", "use the saved password for target"])
        #expect(rig.presenter.questions.isEmpty)
        let whoami = try await rig.run(on: Rig.targetID, "whoami")
        #expect(whoami.outputText == TestSSHD.targetUser + "\n", "\(whoami.errorText)")
        await rig.finish()
    }

    @Test func aJumpHopUsesTheJumpHostsOwnMaster() async throws {
        let rig = try Rig(saved: [Rig.jumpRef: TestSSHD.jumpPassword, Rig.targetRef: TestSSHD.targetPassword])
        let jump = try await rig.master(Rig.jumpID)
        await expectReady(jump)
        #expect(rig.presence.reasons.count == 1)
        let target = try await rig.master(Rig.targetID)
        await expectReady(target)
        // Only the target's own login: the hop went through the jump host's master.
        #expect(rig.presence.reasons.count == 2)
        await rig.finish()
    }

    @Test func panesUseTheMasterWithoutLoggingIn() async throws {
        let rig = try Rig(saved: [Rig.jumpRef: TestSSHD.jumpPassword])
        let master = try await rig.master(Rig.jumpID)
        await expectReady(master)
        for _ in 0..<3 {
            let result = try await rig.run(on: Rig.jumpID, "echo hello from $USER")
            #expect(result.outputText == "hello from \(TestSSHD.jumpUser)\n", "\(result.errorText)")
        }
        #expect(rig.presence.reasons.count == 1)
        // With the master gone, BatchMode can't log in: the panes above did use it.
        master.end()
        _ = await ending(of: master)
        let alone = try await rig.run(on: Rig.jumpID, "true")
        #expect(!alone.succeeded)
        await rig.finish()
    }

    // MARK: - Saying no

    @Test func cancellingEndsTheAttemptAfterOneQuestion() async throws {
        let rig = try Rig(answers: [.cancel])
        let master = try await rig.master(Rig.jumpID)
        #expect(await settle(master) == .ended(.failed(.cancelled)))
        #expect(rig.presenter.questions.count == 1)
        await rig.finish()
    }

    @Test func decliningTouchIDEndsTheAttempt() async throws {
        let rig = try Rig(saved: [Rig.jumpRef: TestSSHD.jumpPassword], touchID: false)
        let master = try await rig.master(Rig.jumpID)
        #expect(await settle(master) == .ended(.failed(.cancelled)))
        #expect(rig.presence.reasons.count == 1)
        #expect(rig.presenter.questions.isEmpty)
        await rig.finish()
    }

    @Test func aWrongSavedPasswordLeadsToAQuestion() async throws {
        let rig = try Rig(
            saved: [Rig.jumpRef: "not-the-password"], answers: [.text(TestSSHD.jumpPassword, remember: true)])
        let master = try await rig.master(Rig.jumpID)
        await expectReady(master)
        #expect(rig.presence.reasons.count == 1)
        let question = try #require(rig.presenter.questions.first)
        #expect(question.savedSecretFailed)
        #expect(try await rig.secrets.read(Rig.jumpRef) == TestSSHD.jumpPassword)
        await rig.finish()
    }

    @Test func aRefusedPasswordSaysSoAndIsntSaved() async throws {
        let rig = try Rig(
            settings: ["PreferredAuthentications keyboard-interactive", "NumberOfPasswordPrompts 1"],
            answers: [.text("not-the-password", remember: true)])
        let master = try await rig.master(Rig.jumpID)
        let state = await settle(master)
        guard case .ended(.failed(.authenticationFailed)) = state else {
            Issue.record("Expected a refused login, got \(state): \(master.log.lines)")
            await rig.finish()
            return
        }
        #expect(!rig.secrets.contains(Rig.jumpRef))
        await rig.finish()
    }

    @Test func backgroundWorkStopsInsteadOfAsking() async throws {
        let rig = try Rig(saved: [Rig.jumpRef: TestSSHD.jumpPassword])
        let master = try await rig.master(Rig.jumpID, mayAsk: false)
        #expect(await settle(master) == .ended(.failed(.cancelled)))
        #expect(rig.presence.reasons.isEmpty)
        await rig.finish()
    }

    // MARK: - Ending

    @Test func nothingListeningSaysRefused() async throws {
        let rig = try Rig()
        let master = try await rig.master(Rig.closedID)
        #expect(await settle(master) == .ended(.failed(.refused)))
        await rig.finish()
    }

    @Test func aMasterKilledFromOutsideSaysSoAndLeavesNoSocket() async throws {
        let rig = try Rig(saved: [Rig.jumpRef: TestSSHD.jumpPassword])
        let master = try await rig.master(Rig.jumpID)
        await expectReady(master)
        let pid = try #require(master.pid)
        kill(pid, SIGKILL)
        #expect(await ending(of: master) == .failed(.other("ssh was ended by signal 9.")))
        #expect(!FileManager.default.fileExists(atPath: master.controlPath))
        await rig.finish()
    }

    @Test func leftoversFromACrashAreEnded() async throws {
        let rig = try Rig(saved: [Rig.jumpRef: TestSSHD.jumpPassword])
        let master = try await rig.master(Rig.jumpID)
        await expectReady(master)
        // As if the app had crashed: nobody ends it, and the next launch finds its socket.
        let ended = await MasterSupervisor.cleanUpLeftovers(
            in: rig.paths.controlFolder, runner: SystemProcessRunner(), environment: ["PATH": "/usr/bin:/bin"])
        #expect(ended == 1)
        let ending = await ending(of: master)
        #expect(ending != .closed)
        #expect(!FileManager.default.fileExists(atPath: master.controlPath))
        await rig.finish()
    }

    // MARK: - Keys

    @Test func aKeyAddedThroughTheMasterIsAddedOnceAndLogsIn() async throws {
        let rig = try Rig(saved: [Rig.jumpRef: TestSSHD.jumpPassword])
        let master = try await rig.master(Rig.jumpID)
        await expectReady(master)
        let key = rig.folder + "/id_test"
        let made = try ChildProcess.run(
            executable: "/usr/bin/ssh-keygen",
            arguments: ["ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-C", "Death Race test", "-f", key],
            environment: ["PATH": "/usr/bin:/bin"])
        try #require(made.succeeded, "\(made.errorText)")
        let publicKey = try String(contentsOfFile: key + ".pub", encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let blob = String(publicKey.split(separator: " ")[1])
        let alias = try #require(rig.config.aliases[Rig.jumpID])
        for _ in 0..<2 {
            try await AuthorizedKeys.install(
                publicKey, alias: alias, config: rig.paths.generatedConfig, runner: SystemProcessRunner(),
                environment: ["PATH": "/usr/bin:/bin"])
        }
        let count = try await rig.run(on: Rig.jumpID, "grep -cF \(blob) ~/.ssh/authorized_keys")
        #expect(count.outputText == "1\n")

        // The key logs in by itself, with no master and no password.
        let login = try await SystemProcessRunner().run(
            Command(
                [
                    "/usr/bin/ssh", "-F", "none", "-i", key, "-o", "IdentitiesOnly=yes", "-o", "BatchMode=yes",
                    "-o", "StrictHostKeyChecking=no", "-o", "UserKnownHostsFile=/dev/null", "-p",
                    String(TestSSHD.jump.port), "\(TestSSHD.jumpUser)@\(TestSSHD.jump.address)", "echo", "key-works",
                ], environment: ["PATH": "/usr/bin:/bin"]))
        #expect(login.outputText == "key-works\n", "\(login.errorText)")

        // Leave the server as it was.
        _ = try await rig.run(
            on: Rig.jumpID,
            "grep -vF \(blob) ~/.ssh/authorized_keys > ~/.ssh/k.tmp; mv ~/.ssh/k.tmp ~/.ssh/authorized_keys")
        await rig.finish()
    }

    // MARK: - Come & Go

    @Test func localRemoteAndDynamicForwardsCarryTrafficAndClose() async throws {
        let rig = try Rig(saved: [Rig.jumpRef: TestSSHD.jumpPassword])
        let master = try await rig.master(Rig.jumpID)
        await expectReady(master)
        let echo = try EchoServer()
        defer { echo.stop() }
        let tunnels = rig.tunnels

        let local = TunnelSpec(
            kind: .local, listenPort: try freePort(), target: .init(host: "127.0.0.1", port: echo.port))
        try await tunnels.open(local, socket: master.controlPath)
        #expect(roundTrip(port: local.listenPort, "local") == "local")
        try await tunnels.close(local, socket: master.controlPath)
        #expect(await eventually { !connects(port: local.listenPort) })

        let remote = TunnelSpec(
            kind: .remote, listenPort: try freePort(), target: .init(host: "127.0.0.1", port: echo.port))
        try await tunnels.open(remote, socket: master.controlPath)
        #expect(await eventually { connects(port: remote.listenPort) })
        #expect(roundTrip(port: remote.listenPort, "remote") == "remote")
        try await tunnels.close(remote, socket: master.controlPath)
        #expect(await eventually { !connects(port: remote.listenPort) })

        let dynamic = TunnelSpec(kind: .dynamic, listenPort: try freePort())
        try await tunnels.open(dynamic, socket: master.controlPath)
        #expect(socksRoundTrip(proxyPort: dynamic.listenPort, to: echo.port, "socks") == "socks")
        try await tunnels.close(dynamic, socket: master.controlPath)
        #expect(await eventually { !connects(port: dynamic.listenPort) })

        // Turning tunnels on and off never needed another login.
        #expect(rig.presence.reasons.count == 1)
        #expect(master.state == .ready)
        await rig.finish()
    }

    @Test func aTunnelThatCantOpenSaysWhy() async throws {
        let rig = try Rig(saved: [Rig.jumpRef: TestSSHD.jumpPassword])
        let master = try await rig.master(Rig.jumpID)
        await expectReady(master)
        let echo = try EchoServer()
        defer { echo.stop() }
        let tunnels = rig.tunnels

        // In use on this machine.
        let taken = TunnelSpec(kind: .local, listenPort: echo.port, target: .init(host: "127.0.0.1", port: 22))
        await #expect(throws: TunnelController.Failure.portInUse(echo.port)) {
            try await tunnels.open(taken, socket: master.controlPath)
        }
        // In use on the server. Bound to IPv4 loopback only: on "localhost" sshd would listen
        // on ::1 as well, and one address family taking it counts as success.
        let refused = TunnelSpec(
            kind: .remote, bindAddress: "127.0.0.1", listenPort: echo.port,
            target: .init(host: "127.0.0.1", port: echo.port))
        do {
            try await tunnels.open(refused, socket: master.controlPath)
            Issue.record("The server shouldn't have let port \(echo.port) be taken twice")
        } catch {
            guard case .refused = error else {
                Issue.record("Expected a refusal, got \(error)")
                await rig.finish()
                return
            }
        }
        // No master there.
        let spare = TunnelSpec(kind: .dynamic, listenPort: try freePort())
        await #expect(throws: TunnelController.Failure.noConnection) {
            try await tunnels.open(spare, socket: rig.paths.controlFolder + "/0000000000000000")
        }
        #expect(master.state == .ready)
        await rig.finish()
    }
}

/// Expects `master` to connect, and says how it ended and what ssh wrote if it didn't.
private func expectReady(_ master: MasterSupervisor, sourceLocation: SourceLocation = #_sourceLocation) async {
    let state = await settle(master)
    #expect(state == .ready, "\(state): \(master.log.lines)", sourceLocation: sourceLocation)
}

/// Every master a pool reported ending, in order.
final class EndingLog: Sendable {
    private let endings = Locked<[(String, MasterSupervisor.Ending)]>([])

    func add(_ key: String, _ ending: MasterSupervisor.Ending) { endings.withLock { $0.append((key, ending)) } }
    var all: [String] { endings.withLock { $0.map { "\($0.0): \($0.1)" } } }
    var count: Int { endings.withLock { $0.count } }
}

@Suite("The pool of masters, against a real sshd", .serialized, .enabled(if: TestSSHD.isAvailable))
struct MasterPoolTests {
    @Test func usersOfOneHostShareOneMasterAndOneLogin() async throws {
        let rig = try Rig(saved: [Rig.jumpRef: TestSSHD.jumpPassword])
        let pool = try rig.pool()
        let jump = try rig.target(Rig.jumpID)
        async let first = pool.connect(jump, for: "pane-1", secrets: rig.saved)
        async let second = pool.connect(jump, for: "pane-2", secrets: rig.saved)
        #expect(await [first, second] == [.ready, .ready])
        #expect(rig.presence.reasons == ["use the saved password for jump"])
        #expect(pool.connected == [Rig.jumpID.rawValue])
        // A third, later, joins at once.
        #expect(await pool.connect(jump, for: "pane-3", secrets: rig.saved) == .ready)
        #expect(rig.presence.reasons.count == 1)
        let whoami = try await rig.run(on: Rig.jumpID, "whoami")
        #expect(whoami.outputText == TestSSHD.jumpUser + "\n")
        await pool.endAll()
        await rig.finish()
    }

    @Test func theLastUserLeavingClosesItAfterTheIdleTime() async throws {
        let rig = try Rig(saved: [Rig.jumpRef: TestSSHD.jumpPassword])
        let endings = EndingLog()
        let pool = try rig.pool(idleClose: .milliseconds(300), endings: endings)
        let jump = try rig.target(Rig.jumpID)
        #expect(await pool.connect(jump, for: "pane-1", secrets: rig.saved) == .ready)
        #expect(await pool.connect(jump, for: "pane-2", secrets: rig.saved) == .ready)
        pool.release("pane-1")
        try await Task.sleep(for: .milliseconds(600))
        // pane-2 still uses it.
        #expect(pool.connected == [Rig.jumpID.rawValue])
        pool.release("pane-2")
        // Coming back within the idle time keeps it, with no new login.
        try await Task.sleep(for: .milliseconds(100))
        #expect(await pool.connect(jump, for: "pane-3", secrets: rig.saved) == .ready)
        try await Task.sleep(for: .milliseconds(600))
        #expect(pool.connected == [Rig.jumpID.rawValue])
        #expect(rig.presence.reasons.count == 1)
        pool.release("pane-3")
        #expect(await eventually { pool.connected.isEmpty })
        #expect(await eventually { endings.all == ["h-jump: closed"] })
        await rig.finish()
    }

    // Closing the only pane on a jump host must not take down the hosts behind it: their
    // ProxyJump hops reuse that master's socket, so it stays up while anything needs it.
    @Test func aJumpHostStaysUpWhileAHostBehindItIsConnected() async throws {
        let rig = try Rig(saved: [Rig.jumpRef: TestSSHD.jumpPassword, Rig.targetRef: TestSSHD.targetPassword])
        let endings = EndingLog()
        let pool = try rig.pool(idleClose: .milliseconds(300), endings: endings)
        #expect(await pool.connect(try rig.target(Rig.jumpID), for: "pane-jump", secrets: rig.saved) == .ready)
        #expect(await pool.connect(try rig.target(Rig.targetID), for: "pane-target", secrets: rig.saved) == .ready)
        #expect(pool.connected == [Rig.jumpID.rawValue, Rig.targetID.rawValue])

        // Close the jump pane. Well past the idle time, both masters are still up: the target
        // behind it holds the jump host open.
        pool.release("pane-jump")
        try await Task.sleep(for: .milliseconds(600))
        #expect(pool.connected == [Rig.jumpID.rawValue, Rig.targetID.rawValue])
        #expect(endings.all.isEmpty)

        // Close the target too, and now both idle out: the target first, then the jump host
        // once the target's hold is released.
        pool.release("pane-target")
        #expect(await eventually { pool.connected.isEmpty })
        #expect(await eventually { Set(endings.all) == ["h-jump: closed", "h-target: closed"] })
        await rig.finish()
    }

    @Test func eachHopIsAskedOnceThroughTheJumpHostsOwnMaster() async throws {
        let rig = try Rig(saved: [Rig.jumpRef: TestSSHD.jumpPassword, Rig.targetRef: TestSSHD.targetPassword])
        let pool = try rig.pool()
        #expect(await pool.connect(try rig.target(Rig.jumpID), for: "pane-1", secrets: rig.saved) == .ready)
        #expect(await pool.connect(try rig.target(Rig.targetID), for: "pane-2", secrets: rig.saved) == .ready)
        #expect(rig.presence.reasons == ["use the saved password for jump", "use the saved password for target"])
        #expect(pool.connected == [Rig.jumpID.rawValue, Rig.targetID.rawValue])
        await pool.endAll()
        #expect(pool.connected.isEmpty)
        await rig.finish()
    }

    @Test func cancellingTheQuestionCancelsTheConnection() async throws {
        let rig = try Rig(answers: [.cancel])
        let endings = EndingLog()
        let pool = try rig.pool(endings: endings)
        #expect(
            await pool.connect(try rig.target(Rig.jumpID), for: "pane-1", secrets: rig.saved) == .failed(.cancelled))
        #expect(pool.master(for: Rig.jumpID.rawValue) == nil)
        #expect(endings.all == ["h-jump: failed(SSHKit.ConnectionFailure.cancelled)"])
        await rig.finish()
    }

    // Reconnecting to a host whose master is being ended must start a fresh master, not join
    // the dying one (which handed back .cancelled). The new connect waits for the old socket
    // to go, then logs in again.
    @Test func reconnectingWhileAMasterIsEndingStartsAfresh() async throws {
        let rig = try Rig(saved: [Rig.jumpRef: TestSSHD.jumpPassword])
        let pool = try rig.pool()
        let jump = try rig.target(Rig.jumpID)
        #expect(await pool.connect(jump, for: "pane-1", secrets: rig.saved) == .ready)
        pool.cancel(Rig.jumpID.rawValue)
        #expect(await pool.connect(jump, for: "pane-2", secrets: rig.saved) == .ready)
        #expect(pool.connected == [Rig.jumpID.rawValue])
        let whoami = try await rig.run(on: Rig.jumpID, "whoami")
        #expect(whoami.outputText == TestSSHD.jumpUser + "\n")
        await pool.endAll()
        await rig.finish()
    }

    @Test func aFailedConnectionIsTriedAfreshNextTime() async throws {
        let rig = try Rig()
        let pool = try rig.pool()
        let closed = try rig.target(Rig.closedID)
        #expect(await pool.connect(closed, for: "pane-1") == .failed(.refused))
        #expect(pool.master(for: Rig.closedID.rawValue) == nil)
        #expect(await pool.connect(closed, for: "pane-1") == .failed(.refused))
        await rig.finish()
    }
}

@Suite("Come & Go, against a real sshd", .serialized, .enabled(if: TestSSHD.isAvailable))
struct TunnelBoardTests {
    private func tunnel(_ kind: TunnelSpec.Kind, listen: Int, to port: Int? = nil, opensWithConnection: Bool = false)
        -> Tunnel
    {
        Tunnel(
            spec: TunnelSpec(kind: kind, listenPort: listen, target: port.map { .init(host: "127.0.0.1", port: $0) }),
            opensWithConnection: opensWithConnection)
    }

    @Test func aTunnelOpensItsHostsMasterAndClosingLetsItGo() async throws {
        let rig = try Rig(saved: [Rig.jumpRef: TestSSHD.jumpPassword])
        let pool = try rig.pool(idleClose: .milliseconds(200))
        let board = TunnelBoard(pool: pool, controller: rig.tunnels, now: { Date(timeIntervalSince1970: 0) })
        let echo = try EchoServer()
        defer { echo.stop() }
        let local = tunnel(.local, listen: try freePort(), to: echo.port)

        // No pane: the tunnel starts the master itself.
        let state = await board.open(local, on: try rig.target(Rig.jumpID), secrets: rig.saved)
        #expect(state == .open(since: Date(timeIntervalSince1970: 0)))
        #expect(pool.connected == [Rig.jumpID.rawValue])
        #expect(board.openCount == 1)
        #expect(roundTrip(port: local.spec.listenPort, "come") == "come")
        #expect(
            board.row(local.id)?.text(time: { _ in "10:42" })
                == "\(local.spec.listenPort) → 127.0.0.1:\(echo.port) · Local · on jump · open since 10:42")

        await board.close(local.id)
        #expect(board.openCount == 0)
        #expect(board.row(local.id)?.state == .closed)
        #expect(await eventually { !connects(port: local.spec.listenPort) })
        // The last user gone, the master follows after its idle time.
        #expect(await eventually { pool.connected.isEmpty })
        await rig.finish()
    }

    @Test func closingATunnelLeavesThePanesMasterUp() async throws {
        let rig = try Rig(saved: [Rig.jumpRef: TestSSHD.jumpPassword])
        let pool = try rig.pool(idleClose: .milliseconds(200))
        let board = TunnelBoard(pool: pool, controller: rig.tunnels)
        let jump = try rig.target(Rig.jumpID)
        #expect(await pool.connect(jump, for: "pane-1", secrets: rig.saved) == .ready)
        let dynamic = tunnel(.dynamic, listen: try freePort())
        await board.open(dynamic, on: jump)
        #expect(board.row(dynamic.id)?.isOpen == true)
        await board.close(dynamic.id)
        try await Task.sleep(for: .milliseconds(500))
        #expect(pool.connected == [Rig.jumpID.rawValue])
        #expect(rig.presence.reasons.count == 1)
        await pool.endAll()
        await rig.finish()
    }

    @Test func aTunnelThatCantOpenSaysWhyAndHoldsNoMaster() async throws {
        let rig = try Rig(saved: [Rig.jumpRef: TestSSHD.jumpPassword])
        let pool = try rig.pool(idleClose: .milliseconds(200))
        let board = TunnelBoard(pool: pool, controller: rig.tunnels)
        let echo = try EchoServer()
        defer { echo.stop() }
        let taken = tunnel(.local, listen: echo.port, to: 22)
        #expect(
            await board.open(taken, on: try rig.target(Rig.jumpID), secrets: rig.saved)
                == .failed("Port \(echo.port) is in use on this Mac."))
        #expect(board.openCount == 0)
        #expect(await eventually { pool.connected.isEmpty })

        let unreachable = tunnel(.dynamic, listen: try freePort())
        #expect(
            await board.open(unreachable, on: try rig.target(Rig.closedID)) == .failed("closed refused the connection.")
        )
        await rig.finish()
    }

    @Test func tunnelsThatOpenWithTheConnectionDoAndCloseWithIt() async throws {
        let rig = try Rig(saved: [Rig.jumpRef: TestSSHD.jumpPassword])
        let endings = EndingLog()
        let board = Locked<TunnelBoard?>(nil)
        let pool = MasterPool(
            broker: rig.broker,
            settings: MasterPool.Settings(
                config: rig.paths.generatedConfig, helper: rig.helper, environment: ["PATH": "/usr/bin:/bin"]),
            onEnd: { key, ending in
                endings.add(key, ending)
                board.withLock { $0 }?.hostEnded(key)
            })
        let tunnels = TunnelBoard(pool: pool, controller: rig.tunnels)
        board.withLock { $0 = tunnels }
        let jump = try rig.target(Rig.jumpID)
        let always = tunnel(.dynamic, listen: try freePort(), opensWithConnection: true)
        let sometimes = tunnel(.dynamic, listen: try freePort())

        #expect(await pool.connect(jump, for: "pane-1", secrets: rig.saved) == .ready)
        await tunnels.openWithConnection([always, sometimes], on: jump)
        #expect(tunnels.row(always.id)?.isOpen == true)
        #expect(tunnels.row(sometimes.id) == nil)

        // The master goes (the network dropped): its tunnels say so.
        let pid = try #require(pool.master(for: jump.key)?.pid)
        kill(pid, SIGKILL)
        #expect(await eventually { tunnels.openCount == 0 })
        #expect(tunnels.row(always.id)?.state == .failed("closed when the connection to jump ended"))
        await rig.finish()
    }

    @Test func aTunnelThatCantCancelSaysSoInsteadOfLookingClosed() async throws {
        let rig = try Rig(saved: [Rig.jumpRef: TestSSHD.jumpPassword])
        let pool = try rig.pool(idleClose: .milliseconds(200))
        let board = TunnelBoard(pool: pool, controller: rig.tunnels)
        let echo = try EchoServer()
        defer { echo.stop() }
        let jump = try rig.target(Rig.jumpID)
        let local = tunnel(.local, listen: try freePort(), to: echo.port)
        await board.open(local, on: jump, secrets: rig.saved)
        #expect(board.row(local.id)?.isOpen == true)

        // Pull the control socket out from under the master so `-O cancel` can't reach it: the
        // local port stays bound, so the row must say the close failed, not report it closed.
        let controlPath = try #require(pool.master(for: jump.key)?.controlPath)
        try FileManager.default.removeItem(atPath: controlPath)
        await board.close(local.id)
        #expect(board.row(local.id)?.state == .failed("The connection isn't open."))
        #expect(board.openCount == 0)

        await pool.endAll()
        await rig.finish()
    }
}

// MARK: - Sockets for the tunnel tests

private func makeSocket() -> Int32 {
    #if canImport(Darwin)
        socket(AF_INET, SOCK_STREAM, 0)
    #else
        socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
    #endif
}

private func loopback(port: Int) -> sockaddr_in {
    var address = sockaddr_in()
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = in_port_t(UInt16(port).bigEndian)
    address.sin_addr.s_addr = inet_addr("127.0.0.1")
    return address
}

private func connect(_ fd: Int32, port: Int) -> Bool {
    var address = loopback(port: port)
    return withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
        }
    }
}

/// A port nothing listens on just now.
private func freePort() throws -> Int {
    let fd = makeSocket()
    defer { close(fd) }
    var address = loopback(port: 0)
    var length = socklen_t(MemoryLayout<sockaddr_in>.size)
    let bound = withUnsafeMutablePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            bind(fd, $0, length) == 0 && getsockname(fd, $0, &length) == 0
        }
    }
    try #require(bound)
    return Int(UInt16(bigEndian: address.sin_port))
}

private func connects(port: Int) -> Bool {
    let fd = makeSocket()
    defer { close(fd) }
    return connect(fd, port: port)
}

private func withTimeouts(_ fd: Int32) {
    var timeout = timeval(tv_sec: 5, tv_usec: 0)
    _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    _ = setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
}

private func send(_ fd: Int32, _ bytes: [UInt8]) -> Bool {
    bytes.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) } == bytes.count
}

private func receive(_ fd: Int32, count: Int) -> [UInt8]? {
    var bytes: [UInt8] = []
    var buffer = [UInt8](repeating: 0, count: count)
    while bytes.count < count {
        let got = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, count - bytes.count) }
        guard got > 0 else { return nil }
        bytes += buffer[0..<got]
    }
    return bytes
}

/// Sends `text` to 127.0.0.1:`port` and returns the echo; nil if nothing came back.
private func roundTrip(port: Int, _ text: String) -> String? {
    let fd = makeSocket()
    defer { close(fd) }
    withTimeouts(fd)
    guard connect(fd, port: port), send(fd, Array(text.utf8)) else { return nil }
    return receive(fd, count: text.utf8.count).map { String(decoding: $0, as: UTF8.self) }
}

/// The same through a SOCKS5 proxy: no authentication, CONNECT to 127.0.0.1:`port`.
private func socksRoundTrip(proxyPort: Int, to port: Int, _ text: String) -> String? {
    let fd = makeSocket()
    defer { close(fd) }
    withTimeouts(fd)
    guard connect(fd, port: proxyPort), send(fd, [5, 1, 0]), receive(fd, count: 2) == [5, 0] else { return nil }
    let request: [UInt8] = [5, 1, 0, 1, 127, 0, 0, 1, UInt8(port >> 8), UInt8(port & 0xFF)]
    guard send(fd, request), let reply = receive(fd, count: 10), reply[1] == 0 else { return nil }
    guard send(fd, Array(text.utf8)) else { return nil }
    return receive(fd, count: text.utf8.count).map { String(decoding: $0, as: UTF8.self) }
}

/// Echoes whatever 127.0.0.1:`port` receives, a thread per connection.
private final class EchoServer: Sendable {
    let port: Int
    private let listener: Int32

    init() throws {
        listener = makeSocket()
        var address = loopback(port: 0)
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let fd = listener
        let ready = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, length) == 0 && listen(fd, 16) == 0 && getsockname(fd, $0, &length) == 0
            }
        }
        try #require(ready)
        port = Int(UInt16(bigEndian: address.sin_port))
        Thread {
            while true {
                let client = accept(fd, nil, nil)
                guard client >= 0 else { return }
                Thread {
                    defer { close(client) }
                    var buffer = [UInt8](repeating: 0, count: 4_096)
                    while true {
                        let got = buffer.withUnsafeMutableBytes { read(client, $0.baseAddress, $0.count) }
                        guard got > 0, send(client, Array(buffer[0..<got])) else { return }
                    }
                }.start()
            }
        }.start()
    }

    func stop() {
        shutdown(listener, Int32(SHUT_RDWR))
        close(listener)
    }
}
