import Foundation
import Vault

/// The ssh_config WRLD compiles to, `~/.deathrace/ssh_config`, which every ssh Death Race
/// starts reads with `-F`.
///
/// ```
/// Host deathrace-prod-api
///     HostName 10.0.4.21
///     User ubuntu
///     IdentityFile /Users/r/.deathrace/keys/se-3f2a9c
///     IdentitiesOnly yes
///     SecurityKeyProvider /usr/lib/ssh-keychain.dylib
///     ProxyJump deathrace-bastion
///     ControlMaster no
///     ControlPersist no
///     ControlPath /Users/r/.deathrace/cm/3f2a9c41d07be5aa
/// Host nas-999
///     ControlMaster no
///     ControlPersist no
///     ControlPath /Users/r/.deathrace/cm/8be21c0f9a6d4e13
/// Match all
/// Include ~/.ssh/config
/// Include /etc/ssh/ssh_config
/// ```
///
/// - First value wins in ssh, so WRLD's settings come first and your own `Host *` defaults
///   (agent, keep-alives, Apple's `SendEnv`) still fill in everything WRLD doesn't set.
/// - Every block says `ControlMaster no` and `ControlPersist no`: only the app's master
///   command passes `-M`, and your own `ControlPersist 10m` must never put our master in
///   the background, where it would outlive the app.
/// - Hosts from `~/.ssh/config` get a block with only the control settings: your config
///   decides the rest. `-F` reaches ProxyJump's hops and `-o` doesn't, so this is how a
///   jump hop finds its host's master.
/// - `Match all` before the includes: an `Include` inside the last `Host` block would only
///   apply to that host.
/// - Every value is checked. A newline in a field could add a `ProxyCommand` line, which
///   runs code; such a host is left out, with a reason.
public struct GeneratedConfig: Equatable, Sendable {
    public struct Problem: Equatable, Sendable {
        public var host: HostID
        public var message: String

        public init(host: HostID, message: String) {
            self.host = host
            self.message = message
        }
    }

    /// macOS's provider for Secure Enclave keys.
    public static let secureEnclaveProvider = "/usr/lib/ssh-keychain.dylib"
    /// Your config, then Apple's: `-F` replaces both, so both are included back.
    public static let standardIncludes = ["~/.ssh/config", "/etc/ssh/ssh_config"]

    public let text: String
    /// Each host's name in the file, for `ssh -F … <alias>`.
    public let aliases: [HostID: String]
    /// Each host's control socket.
    public let controlPaths: [HostID: String]
    /// The control socket of each alias from `~/.ssh/config` that WRLD doesn't hold.
    public let aliasControlPaths: [String: String]
    /// Hosts left out, and why.
    public let problems: [Problem]

    /// `aliases` are the concrete names in `~/.ssh/config`: each gets a control-only block
    /// too, so connecting to one from Hear Me Calling also gets a master the app owns, and
    /// jump hops through it reuse that master.
    public init(
        vault: Vault, paths: WRLDPaths, includes: [String] = standardIncludes, aliases discovered: [String] = []
    ) {
        var problems: [Problem] = []

        // 1. Names, so a host can point at a jump host listed after it.
        var aliases: [HostID: String] = [:]
        var taken: Set<String> = []
        for host in vault.hosts {
            switch host.source {
            case .wrld:
                let alias = Self.uniqueAlias(for: host.name, taken: taken)
                taken.insert(alias)
                aliases[host.id] = alias
            case .sshConfig(let alias):
                if SSHConfigDiscovery.isConcrete(alias), Self.isHostName(alias) {
                    aliases[host.id] = alias
                } else {
                    problems.append(Problem(host: host.id, message: "“\(alias)” isn't a host name ssh can look up."))
                }
            }
        }

        // 2. Each host's own settings, checked.
        var settings: [HostID: [String]] = [:]
        for host in vault.hosts where aliases[host.id] != nil {
            guard let connection = host.connection else {
                settings[host.id] = []
                continue
            }
            do {
                settings[host.id] = try Self.connectionLines(connection, vault: vault)
            } catch {
                problems.append(Problem(host: host.id, message: error.message))
                aliases[host.id] = nil
            }
        }

        // 3. A host whose jump host is missing, left out, or leads back to it is left out too.
        var changed = true
        while changed {
            changed = false
            for host in vault.hosts where aliases[host.id] != nil {
                guard let jump = host.connection?.jumpHostID else { continue }
                let reason: String?
                if jump == host.id || Self.jumpsInACircle(from: host.id, vault: vault) {
                    reason = "Its jump hosts lead back to it."
                } else if vault.host(jump) == nil {
                    reason = "Its jump host is missing."
                } else if aliases[jump] == nil {
                    reason = "\(vault.host(jump)?.name ?? "Its jump host") can't be reached, so neither can this host."
                } else {
                    reason = nil
                }
                if let reason {
                    problems.append(Problem(host: host.id, message: reason))
                    aliases[host.id] = nil
                    changed = true
                }
            }
        }

        // 4. The blocks, in the vault's order; an alias named twice gets one.
        var blocks: [String] = []
        var written: Set<String> = []
        var controlPaths: [HostID: String] = [:]
        for host in vault.hosts {
            guard let alias = aliases[host.id], var lines = settings[host.id] else { continue }
            let controlPath = paths.controlPath(for: Self.controlKey(for: host))
            controlPaths[host.id] = controlPath
            guard written.insert(alias).inserted else { continue }
            if let jump = host.connection?.jumpHostID, let jumpAlias = aliases[jump] {
                lines.append("ProxyJump " + jumpAlias)
            }
            lines += ["ControlMaster no", "ControlPersist no", "ControlPath " + Self.pathValue(controlPath)]
            blocks.append((["Host " + alias] + lines.map { "    " + $0 }).joined(separator: "\n"))
        }
        var aliasControlPaths: [String: String] = [:]
        for alias in discovered where SSHConfigDiscovery.isConcrete(alias) && Self.isHostName(alias) {
            guard written.insert(alias).inserted else { continue }
            let controlPath = paths.controlPath(for: Self.controlKey(forAlias: alias))
            aliasControlPaths[alias] = controlPath
            let lines = ["ControlMaster no", "ControlPersist no", "ControlPath " + Self.pathValue(controlPath)]
            blocks.append((["Host " + alias] + lines.map { "    " + $0 }).joined(separator: "\n"))
        }

        var text = """
            # Written by Death Race for Code from WRLD (wrld.json). Edits here are replaced.
            # Your own settings come from the files included at the end.

            """
        for block in blocks { text += "\n" + block + "\n" }
        text += "\nMatch all\n"
        for include in includes { text += "Include " + Self.quotedIfSpaced(include) + "\n" }
        self.text = text
        self.aliases = aliases
        self.controlPaths = controlPaths
        self.aliasControlPaths = aliasControlPaths
        self.problems = problems
    }

    // MARK: - Blocks

    private struct Refusal: Error {
        let message: String
    }

    /// A WRLD host's own settings; its ProxyJump is added once its jump host is known to
    /// be in the file.
    private static func connectionLines(_ connection: Connection, vault: Vault) throws(Refusal) -> [String] {
        guard isHostName(connection.address) else {
            throw Refusal(message: "The address “\(connection.address)” isn't a host name or an IP address.")
        }
        var lines = ["HostName " + connection.address]
        if let user = connection.user {
            guard isUserName(user) else {
                throw Refusal(message: "The user “\(user)” can't be used.")
            }
            lines.append("User " + user)
        }
        if let port = connection.port {
            guard (1...65_535).contains(port) else { throw Refusal(message: "Port \(port) is out of range.") }
            lines.append("Port \(port)")
        }
        switch connection.identity {
        case .automatic:
            break
        case .keyFile(let path):
            guard isPath(path) else { throw Refusal(message: "The key file “\(path)” can't be used.") }
            lines += ["IdentityFile " + pathValue(path), "IdentitiesOnly yes"]
        case .secureEnclave(let keyID):
            guard let key = vault.key(keyID), key.kind == .secureEnclave, isPath(key.handle) else {
                throw Refusal(message: "Its Secure Enclave key is missing.")
            }
            lines += [
                "IdentityFile " + pathValue(key.handle),
                "IdentitiesOnly yes",
                "SecurityKeyProvider " + secureEnclaveProvider,
            ]
        }
        if connection.forwardAgent { lines.append("ForwardAgent yes") }
        return lines
    }

    private static func jumpsInACircle(from start: HostID, vault: Vault) -> Bool {
        var seen: Set<HostID> = [start]
        var next = vault.host(start)?.connection?.jumpHostID
        while let current = next {
            if !seen.insert(current).inserted { return true }
            next = vault.host(current)?.connection?.jumpHostID
        }
        return false
    }

    // MARK: - Names and values

    /// `deathrace-` and the host's name in lowercase letters, digits and dashes, made unique.
    static func uniqueAlias(for name: String, taken: Set<String>) -> String {
        var slug = ""
        for character in name.lowercased() {
            if character.isASCII, character.isLetter || character.isNumber {
                slug.append(character)
            } else if !slug.hasSuffix("-") {
                slug.append("-")
            }
        }
        slug = String(slug.drop(while: { $0 == "-" }).prefix(40))
        while slug.hasSuffix("-") { slug.removeLast() }
        let base = "deathrace-" + (slug.isEmpty ? "host" : slug)
        var alias = base
        var number = 2
        while taken.contains(alias) {
            alias = "\(base)-\(number)"
            number += 1
        }
        return alias
    }

    /// The key a host's control socket is named from: its id, or its alias for a host from
    /// `~/.ssh/config`, so two saved hosts naming one alias share one master.
    public static func controlKey(for host: WRLDHost) -> String {
        switch host.source {
        case .wrld: host.id.rawValue
        case .sshConfig(let alias): controlKey(forAlias: alias)
        }
    }

    public static func controlKey(forAlias alias: String) -> String { "alias:" + alias }

    /// A host name, IP address or alias safe to place in the config, including as a
    /// `ProxyJump` value that OpenSSH runs through a shell. See `SSHValue.isHostName`.
    static func isHostName(_ value: String) -> Bool { SSHValue.isHostName(value) }

    /// A user name safe to place after `User`. See `SSHValue.isUserName`.
    static func isUserName(_ value: String) -> Bool { SSHValue.isUserName(value) }

    /// A path ssh can be given: no control characters or double quotes (spaces are quoted).
    static func isPath(_ value: String) -> Bool { SSHValue.isPath(value) }

    /// A path as a value for `IdentityFile` and `ControlPath`: `%` doubled (ssh expands `%`
    /// tokens in these), and in double quotes when it has a space.
    static func pathValue(_ path: String) -> String {
        quotedIfSpaced(path.replacingOccurrences(of: "%", with: "%%"))
    }

    /// In double quotes when it has a space or a tab (`Include` expands no tokens).
    static func quotedIfSpaced(_ value: String) -> String {
        value.contains(" ") || value.contains("\t") ? "\"\(value)\"" : value
    }
}
