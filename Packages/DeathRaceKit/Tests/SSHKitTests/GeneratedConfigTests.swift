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

private let paths = WRLDPaths(root: "/Users/r/.deathrace")

private func host(
    _ id: String, _ name: String, address: String = "10.0.0.1", user: String? = nil, port: Int? = nil,
    identity: Connection.Identity = .automatic, jump: String? = nil, forwardAgent: Bool = false
) -> WRLDHost {
    WRLDHost(
        id: HostID(rawValue: id), name: name,
        source: .wrld(
            Connection(
                address: address, user: user, port: port, identity: identity, jumpHostID: jump.map(HostID.init),
                forwardAgent: forwardAgent)))
}

private func alias(_ id: String, _ name: String) -> WRLDHost {
    WRLDHost(id: HostID(rawValue: id), name: name, source: .sshConfig(alias: name))
}

private let seKey = Key(
    id: KeyID(rawValue: "k1"), kind: .secureEnclave, label: "Death Race", handle: "/Users/r/.deathrace/keys/se k1",
    publicKey: "sk-ecdsa-sha2-nistp256@openssh.com AAAA")

@Suite("The generated ssh_config")
struct GeneratedConfigTests {
    @Test func aHostWRLDDescribesInFull() {
        let vault = Vault(
            hosts: [
                host("h1", "bastion", address: "bastion.lan", user: "ops"),
                host(
                    "h2", "prod-api", address: "10.0.4.21", user: "ubuntu", port: 2222,
                    identity: .secureEnclave(seKey.id),
                    jump: "h1", forwardAgent: true),
            ], keys: [seKey])
        let config = GeneratedConfig(vault: vault, paths: paths, includes: ["~/.ssh/config"])
        #expect(config.problems.isEmpty)
        #expect(
            config.aliases == [
                HostID(rawValue: "h1"): "deathrace-bastion", HostID(rawValue: "h2"): "deathrace-prod-api",
            ])
        let controlPath = paths.controlPath(for: "h2")
        #expect(config.controlPaths[HostID(rawValue: "h2")] == controlPath)
        #expect(
            config.text.contains(
                """
                Host deathrace-prod-api
                    HostName 10.0.4.21
                    User ubuntu
                    Port 2222
                    IdentityFile "/Users/r/.deathrace/keys/se k1"
                    IdentitiesOnly yes
                    SecurityKeyProvider /usr/lib/ssh-keychain.dylib
                    ForwardAgent yes
                    ProxyJump deathrace-bastion
                    ControlMaster no
                    ControlPersist no
                    ControlPath \(controlPath)
                """))
        // Your settings come after ours, for every host.
        #expect(config.text.hasSuffix("\nMatch all\nInclude ~/.ssh/config\n"))
    }

    @Test func aHostFromSshConfigGetsOnlyItsControlSettings() {
        let vault = Vault(hosts: [alias("h1", "nas-999"), alias("h2", "nas-999")])
        let config = GeneratedConfig(vault: vault, paths: paths)
        #expect(config.problems.isEmpty)
        #expect(config.aliases[HostID(rawValue: "h1")] == "nas-999")
        // Two saved hosts naming one alias share one block and one master.
        #expect(config.text.components(separatedBy: "Host nas-999").count == 2)
        #expect(config.controlPaths[HostID(rawValue: "h1")] == config.controlPaths[HostID(rawValue: "h2")])
        #expect(config.controlPaths[HostID(rawValue: "h1")] == paths.controlPath(for: "alias:nas-999"))
        #expect(
            config.text.contains(
                "Host nas-999\n    ControlMaster no\n    ControlPersist no\n    ControlPath \(paths.controlPath(for: "alias:nas-999"))\n"
            ))
        #expect(config.text.hasSuffix("Match all\nInclude ~/.ssh/config\nInclude /etc/ssh/ssh_config\n"))
    }

    @Test func namesAreMadeUniqueAndSafe() {
        let vault = Vault(hosts: [
            host("h1", "Prod API"), host("h2", "prod api"), host("h3", "  ✨ "), host("h4", "a--b__c"),
        ])
        let config = GeneratedConfig(vault: vault, paths: paths)
        #expect(
            config.aliases == [
                HostID(rawValue: "h1"): "deathrace-prod-api", HostID(rawValue: "h2"): "deathrace-prod-api-2",
                HostID(rawValue: "h3"): "deathrace-host", HostID(rawValue: "h4"): "deathrace-a-b-c",
            ])
    }

    @Test func aFieldThatCouldAddALineIsRefused() {
        let vault = Vault(hosts: [
            host("h1", "evil", address: "10.0.0.1\n    ProxyCommand touch /tmp/pwned"),
            host("h2", "spaced", user: "a b"),
            host("h3", "dashed", address: "-oProxyCommand=x"),
            host("h4", "port", port: 70_000),
            host("h5", "quote", identity: .keyFile("/k\"ey")),
            host("h6", "percent", user: "%u"),
            host("h7", "fine"),
        ])
        let config = GeneratedConfig(vault: vault, paths: paths)
        #expect(Set(config.problems.map(\.host.rawValue)) == ["h1", "h2", "h3", "h4", "h5", "h6"])
        #expect(!config.text.contains("ProxyCommand"))
        #expect(!config.text.contains("evil"))
        #expect(config.aliases.keys.map(\.rawValue) == ["h7"])
    }

    @Test func jumpHostsThatCantWorkTakeTheirHostsWithThem() {
        let vault = Vault(hosts: [
            host("h1", "loop-a", jump: "h2"), host("h2", "loop-b", jump: "h1"),
            host("h3", "self", jump: "h3"),
            host("h4", "orphan", jump: "nope"),
            host("h5", "broken", address: "bad address"),
            host("h6", "behind-broken", jump: "h5"),
            host("h7", "behind-behind", jump: "h6"),
            host("h8", "ok-jump"), host("h9", "behind-ok", jump: "h8"),
        ])
        let config = GeneratedConfig(vault: vault, paths: paths)
        #expect(Set(config.aliases.keys.map(\.rawValue)) == ["h8", "h9"])
        let messages = Dictionary(uniqueKeysWithValues: config.problems.map { ($0.host.rawValue, $0.message) })
        #expect(messages["h1"] == "Its jump hosts lead back to it.")
        #expect(messages["h3"] == "Its jump hosts lead back to it.")
        #expect(messages["h4"] == "Its jump host is missing.")
        #expect(messages["h6"] == "broken can't be reached, so neither can this host.")
        #expect(messages["h7"] == "behind-broken can't be reached, so neither can this host.")
        #expect(!config.text.contains("Host deathrace-behind-broken"))
        #expect(config.text.contains("ProxyJump deathrace-ok-jump"))
    }

    @Test func aMissingSecureEnclaveKeyIsAProblem() {
        let vault = Vault(hosts: [host("h1", "se", identity: .secureEnclave(KeyID(rawValue: "gone")))])
        let config = GeneratedConfig(vault: vault, paths: paths)
        #expect(config.problems == [.init(host: HostID(rawValue: "h1"), message: "Its Secure Enclave key is missing.")])
    }

    @Test func anAliasWithAPatternIsAProblem() {
        let config = GeneratedConfig(vault: Vault(hosts: [alias("h1", "*.internal")]), paths: paths)
        #expect(config.problems.count == 1)
        #expect(config.aliases.isEmpty)
    }

    @Test func pathsArePercentSafeAndQuoted() {
        #expect(GeneratedConfig.pathValue("/a b/%d") == "\"/a b/%%d\"")
        #expect(GeneratedConfig.pathValue("/plain") == "/plain")
        #expect(GeneratedConfig.quotedIfSpaced("/a b/c%") == "\"/a b/c%\"")
    }

    @Test func anEmptyVaultStillIncludesYourConfig() {
        let config = GeneratedConfig(vault: Vault(), paths: paths)
        #expect(config.text.hasSuffix("\nMatch all\nInclude ~/.ssh/config\nInclude /etc/ssh/ssh_config\n"))
        #expect(!config.text.contains("Host "))
    }
}

/// Where Apple's or Ubuntu's ssh is, if this machine has one. CI sets
/// `DEATHRACE_REQUIRE_SSH=1`, so a missing ssh fails there instead of skipping.
enum RealSSH {
    static let path: String? = ["/usr/bin/ssh"].first { access($0, X_OK) == 0 }
    static let isRequired = ProcessInfo.processInfo.environment["DEATHRACE_REQUIRE_SSH"] == "1"
    static var shouldRun: Bool { path != nil || isRequired }
}

@Suite("The generated ssh_config, read by real ssh")
struct GeneratedConfigOpenSSHTests {
    /// `ssh -F config -G alias` in a home of its own.
    func effective(_ alias: String, config: String, home: String) throws -> EffectiveConfig {
        _ = try #require(RealSSH.path, "No ssh at /usr/bin/ssh")
        let arguments = SSHCommand.effectiveConfig(alias: alias, config: config)
        let result = try ChildProcess.run(
            executable: arguments[0], arguments: arguments, environment: ["HOME": home, "PATH": "/usr/bin:/bin"])
        #expect(result.status == .exited(code: 0), "ssh -G \(alias): \(result.errorText)")
        return EffectiveConfig(parsing: result.outputText)
    }

    @Test(.enabled(if: RealSSH.shouldRun)) func oursWinAndYoursFillIn() throws {
        let home = NSTemporaryDirectory() + "wrld-ssh-" + UUID().uuidString
        defer { try? FileManager.default.removeItem(atPath: home) }
        try FileManager.default.createDirectory(atPath: home + "/.ssh", withIntermediateDirectories: true)
        // Your config: defaults that must not win over ours, and a setting only it has.
        let yours = home + "/.ssh/config"
        try """
        Host *
            ControlPersist 10m
            ControlMaster auto
            User other
            ServerAliveInterval 42
        Host nas-999
            HostName 192.168.1.5
        """.write(toFile: yours, atomically: true, encoding: .utf8)

        let paths = WRLDPaths(root: home + "/my %d dir/.deathrace")
        let key = Key(
            id: KeyID(rawValue: "k1"), kind: .secureEnclave, label: "x", handle: home + "/keys/se k1", publicKey: "")
        let vault = Vault(
            hosts: [
                host("h1", "bastion", address: "bastion.lan", user: "ops"),
                host(
                    "h2", "prod-api", address: "10.0.4.21", user: "ubuntu", port: 2222,
                    identity: .secureEnclave(key.id), jump: "h1"),
                alias("h3", "nas-999"),
            ], keys: [key])
        let generated = GeneratedConfig(vault: vault, paths: paths, includes: [yours])
        #expect(generated.problems.isEmpty)
        let file = home + "/generated_config"
        try generated.text.write(toFile: file, atomically: true, encoding: .utf8)

        let prod = try effective("deathrace-prod-api", config: file, home: home)
        #expect(prod.hostName == "10.0.4.21")
        #expect(prod.user == "ubuntu")
        #expect(prod.port == 2222)
        #expect(prod.controlMaster == "false")
        #expect(prod.controlPersist == "no")
        #expect(prod.controlPath == paths.controlPath(for: "h2"))
        #expect(prod.proxyJump == "deathrace-bastion")
        #expect(prod["identitiesonly"] == "yes")
        #expect(prod["securitykeyprovider"] == GeneratedConfig.secureEnclaveProvider)
        #expect(prod.identityFiles.contains(home + "/keys/se k1"))
        #expect(prod["serveraliveinterval"] == "42")

        let nas = try effective("nas-999", config: file, home: home)
        #expect(nas.hostName == "192.168.1.5")
        #expect(nas.user == "other")
        #expect(nas.controlMaster == "false")
        #expect(nas.controlPersist == "no")
        #expect(nas.controlPath == paths.controlPath(for: "alias:nas-999"))

        // A host WRLD doesn't hold is still yours, untouched.
        let other = try effective("elsewhere", config: file, home: home)
        #expect(other.controlMaster == "auto")
        #expect(other.controlPersist == "600")
    }
}
