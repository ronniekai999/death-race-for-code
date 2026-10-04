import Foundation
import PTYKit
import Testing
import Vault

@testable import SSHKit

/// What `ssh -G` prints for a host, the lines HostChain reads.
private func effective(user: String, hostName: String, proxyJump: String = "none", alias: String? = nil) -> ChildResult
{
    .printing(
        """
        user \(user)
        hostname \(hostName)
        port 22
        proxyjump \(proxyJump)
        hostkeyalias \(alias ?? "none")

        """)
}

private let config = "/r/.deathrace/ssh_config"

@Suite("The hops to a host")
struct HostChainTests {
    func resolve(_ alias: String, _ runner: ScriptedRunner) async throws -> HostChain {
        try await HostChain.resolve(alias: alias, config: config, runner: runner, environment: [:])
    }

    @Test func aHostWithNoJumpIsOneHop() async throws {
        let runner = ScriptedRunner([
            ["-F", config, "-G", "deathrace-prod-api"]: effective(user: "ubuntu", hostName: "10.0.4.21")
        ])
        let chain = try await resolve("deathrace-prod-api", runner)
        #expect(
            chain.hops == [
                .init(
                    alias: "deathrace-prod-api", prompt: .init(user: "ubuntu", host: "10.0.4.21"),
                    knownHostsName: "10.0.4.21")
            ])
    }

    @Test func eachJumpHostIsAskedAsSshWillReachIt() async throws {
        // ProxyJump a,ops@b:2222: ssh reaches b with -l ops -p 2222 -J a, and a on its own.
        let runner = ScriptedRunner([
            ["-F", config, "-G", "target"]: effective(user: "ubuntu", hostName: "10.0.4.21", proxyJump: "a,ops@b:2222"),
            ["-F", config, "-G", "-l", "ops", "-p", "2222", "-J", "a", "b"]: effective(
                user: "ops", hostName: "b.internal", proxyJump: "a"),
            ["-F", config, "-G", "a"]: effective(user: "r", hostName: "a.example.com"),
        ])
        let chain = try await resolve("target", runner)
        #expect(chain.hops.map(\.alias) == ["a", "b", "target"])
        #expect(
            chain.hops.map(\.prompt) == [
                .init(user: "r", host: "a.example.com"), .init(user: "ops", host: "b.internal"),
                .init(user: "ubuntu", host: "10.0.4.21"),
            ])
    }

    @Test func aHostKeyAliasIsWhatThePromptNames() async throws {
        let runner = ScriptedRunner([
            ["-F", config, "-G", "nas"]: effective(user: "r", hostName: "192.168.1.5", alias: "nas.home")
        ])
        #expect(try await resolve("nas", runner).hops.first?.prompt == .init(user: "r", host: "nas.home"))
    }

    @Test func jumpHostsThatLoopStop() async throws {
        let runner = ScriptedRunner([
            ["-F", config, "-G", "a"]: effective(user: "r", hostName: "a", proxyJump: "b"),
            ["-F", config, "-G", "b"]: effective(user: "r", hostName: "b", proxyJump: "a"),
        ])
        await #expect(throws: HostChain.Failure.tooDeep) { try await resolve("a", runner) }
    }

    @Test func aConfigSshRefusesSaysWhy() async throws {
        let runner = ScriptedRunner([
            ["-F", config, "-G", "bad"]: .failing("/r/.ssh/config line 3: Bad configuration option: Foo\n")
        ])
        await #expect(
            throws: HostChain.Failure.unreadable("/r/.ssh/config line 3: Bad configuration option: Foo")
        ) { try await resolve("bad", runner) }
    }

    @Test func jumpSpecsReadLikeSshReadsThem() {
        #expect(JumpSpec(parsing: "bastion") == JumpSpec(host: "bastion"))
        #expect(JumpSpec(parsing: "ops@bastion:2222") == JumpSpec(user: "ops", host: "bastion", port: 2222))
        #expect(JumpSpec(parsing: "ssh://ops@bastion:2222") == JumpSpec(user: "ops", host: "bastion", port: 2222))
        #expect(JumpSpec(parsing: "ops@[fd00::5]:2222") == JumpSpec(user: "ops", host: "fd00::5", port: 2222))
        #expect(JumpSpec(parsing: "[fd00::5]") == JumpSpec(host: "fd00::5"))
        #expect(JumpSpec(parsing: "a@b@host") == JumpSpec(user: "a@b", host: "host"))
    }

    // MARK: - What the broker may answer

    @Test func eachSavedPasswordGoesToItsOwnHop() {
        let chain = HostChain(hops: [
            .init(alias: "deathrace-bastion", prompt: .init(user: "ops", host: "bastion.lan")),
            .init(alias: "deathrace-prod-api", prompt: .init(user: "ubuntu", host: "10.0.4.21")),
        ])
        let bastion = SecretRef(.hostPassword, "h-bastion")
        let prod = SecretRef(.hostPassword, "h-prod")
        let context = chain.askpassContext(hostName: "prod-api") { alias in
            switch alias {
            case "deathrace-bastion": (bastion, "bastion")
            case "deathrace-prod-api": (prod, "prod-api")
            default: nil
            }
        }
        #expect(
            context.passwords == [
                .init(user: "ops", host: "bastion.lan"): bastion, .init(user: "ubuntu", host: "10.0.4.21"): prod,
            ])
        #expect(context.name(for: bastion) == "bastion")
        #expect(context.name(for: prod) == "prod-api")
        #expect(context.hostName == "prod-api")
    }

    @Test func hopsTheirPromptsCantTellApartGetNoSavedPassword() {
        // One user on one machine, reached on two ports: the prompts are the same.
        let same = AskpassPrompt.Hop(user: "root", host: "10.0.0.1")
        let chain = HostChain(hops: [.init(alias: "outer", prompt: same), .init(alias: "inner", prompt: same)])
        let both = chain.askpassContext(hostName: "inner") { alias in
            (SecretRef(.hostPassword, alias), alias)
        }
        #expect(both.passwords.isEmpty)
        // Also when only one of them is a WRLD host.
        let one = chain.askpassContext(hostName: "inner") { alias in
            alias == "inner" ? (SecretRef(.hostPassword, alias), alias) : nil
        }
        #expect(one.passwords.isEmpty)
    }

    @Test(.enabled(if: RealSSH.shouldRun)) func realSshAgreesAboutAGeneratedChain() async throws {
        let home = try shortTemporaryFolder()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let include = home + "/user_config"
        try "Host *\n    User fallback\n".write(toFile: include, atomically: true, encoding: .utf8)
        let jump = WRLDHost(
            id: HostID(rawValue: "h1"), name: "bastion", source: .wrld(Connection(address: "bastion.lan", user: "ops")))
        let target = WRLDHost(
            id: HostID(rawValue: "h2"), name: "prod-api",
            source: .wrld(Connection(address: "10.0.4.21", jumpHostID: jump.id)))
        let generated = GeneratedConfig(
            vault: Vault(hosts: [jump, target]), paths: WRLDPaths(root: home + "/dr"), includes: [include])
        let file = home + "/ssh_config"
        try generated.text.write(toFile: file, atomically: true, encoding: .utf8)

        let chain = try await HostChain.resolve(
            alias: try #require(generated.aliases[target.id]), config: file, runner: SystemProcessRunner(),
            environment: ["PATH": "/usr/bin:/bin", "HOME": home])
        #expect(chain.hops.map(\.alias) == ["deathrace-bastion", "deathrace-prod-api"])
        #expect(
            chain.hops.map(\.prompt) == [
                .init(user: "ops", host: "bastion.lan"), .init(user: "fallback", host: "10.0.4.21"),
            ])
        // Each hop carries the name and the files ssh would file its key under, for the
        // changed-key check. ssh resolves "~" from the passwd entry, not our temporary HOME,
        // so only the shape is asserted: an absolute known_hosts path.
        #expect(chain.hops.map(\.knownHostsName) == ["bastion.lan", "10.0.4.21"])
        for hop in chain.hops {
            #expect(hop.knownHostsFiles.contains { $0.hasPrefix("/") && $0.contains("known_hosts") })
        }
    }
}

@Suite("What a failed connection offers")
struct ConnectionOfferTests {
    @Test func theButtons() {
        #expect(ConnectionFailure.noRoute.offers(address: "192.168.1.5") == [.allowLocalNetwork, .reconnect])
        #expect(ConnectionFailure.noRoute.offers(address: "203.0.113.9") == [.reconnect, .plainSSH])
        #expect(ConnectionFailure.noRoute.offers(address: nil) == [.reconnect, .plainSSH])
        #expect(ConnectionFailure.cancelled.offers(address: nil) == [.reconnect])
        #expect(ConnectionFailure.hostKeyRejected.offers(address: nil) == [.reconnect])
        #expect(
            ConnectionFailure.hostKeyChanged(fingerprint: nil, knownHostsLine: nil).offers(address: nil) == [.reconnect]
        )
        let removal = KeyRemoval(file: "/Users/r/.ssh/known_hosts", name: "10.0.4.21")
        #expect(
            ConnectionFailure.hostKeyChanged(fingerprint: nil, knownHostsLine: nil, removal: removal)
                .offers(address: nil) == [.forgetHostKey, .reconnect])
        #expect(
            PaneBanner.failed(
                .hostKeyChanged(fingerprint: nil, knownHostsLine: nil, removal: removal), host: "prod-api",
                address: nil
            ).buttons.map(\.title) == ["Forget the Old Key…", "Reconnect"])
        #expect(
            ConnectionFailure.authenticationFailed(methods: ["password"]).offers(address: "10.0.0.1")
                == [.reconnect, .plainSSH])
    }
}

@Suite("What a pane on a host says")
struct PaneBannerTests {
    @Test func connecting() {
        let banner = PaneBanner.connecting(to: "prod-api")
        #expect(banner.message == "Connecting to prod-api…")
        #expect(banner.buttons == [.cancel])
        #expect(banner.isWorking)
    }

    @Test func aFailureSaysWhyWithWhatMayHelp() {
        let refused = PaneBanner.failed(.authenticationFailed(methods: ["password"]), host: "prod-api", address: nil)
        #expect(refused.buttons == [.reconnect, .plainSSH])
        #expect(!refused.isWorking)
        let lan = PaneBanner.failed(.noRoute, host: "nas-999", address: "192.168.1.5")
        #expect(lan.message == "There's no route to nas-999.")
        #expect(lan.buttons == [.allowLocalNetwork, .reconnect])
        #expect(lan.buttons.map(\.title) == ["Allow Local Network Access…", "Reconnect"])
    }

    @Test func howASessionEnded() {
        #expect(PaneBanner.ended(.exited(code: 0), host: "prod-api", plain: false) == nil)
        #expect(
            PaneBanner.ended(.exited(code: 255), host: "prod-api", plain: false)
                == PaneBanner(message: "The connection to prod-api was lost.", buttons: [.reconnect, .plainSSH]))
        #expect(PaneBanner.ended(.exited(code: 255), host: "prod-api", plain: true)?.buttons == [.reconnect])
        #expect(
            PaneBanner.ended(.exited(code: 3), host: "prod-api", plain: false)?.message
                == "The session on prod-api ended with status 3.")
        #expect(
            PaneBanner.ended(.signaled(signal: 9), host: "prod-api", plain: false)?.message
                == "ssh was ended by signal 9.")
    }
}
