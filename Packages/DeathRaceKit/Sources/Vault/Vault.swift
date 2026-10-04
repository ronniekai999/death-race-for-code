import Foundation

/// WRLD: your saved hosts, their groups, snippets and keys, as kept in `wrld.json`.
///
/// The file is meant to be read and edited by hand and kept in a dotfiles repo, so it is
/// plain JSON with short keys, and it never holds a secret: passwords live in the Keychain,
/// and a Secure Enclave key's private half never leaves the Secure Enclave.
public struct Vault: Equatable, Sendable {
    /// The format this build reads and writes. A file from a newer build is read but never
    /// written over (`VaultStore`).
    public static let formatVersion = 1

    public var version: Int
    public var hosts: [WRLDHost]
    public var groups: [Group]
    public var snippets: [Snippet]
    public var keys: [Key]

    public init(hosts: [WRLDHost] = [], groups: [Group] = [], snippets: [Snippet] = [], keys: [Key] = []) {
        version = Self.formatVersion
        self.hosts = hosts
        self.groups = groups
        self.snippets = snippets
        self.keys = keys
    }

    public func host(_ id: HostID) -> WRLDHost? { hosts.first { $0.id == id } }
    public func group(_ id: GroupID) -> Group? { groups.first { $0.id == id } }
    public func snippet(_ id: SnippetID) -> Snippet? { snippets.first { $0.id == id } }
    public func key(_ id: KeyID) -> Key? { keys.first { $0.id == id } }
}

// MARK: - Identifiers

/// Ids are short random strings with a letter for their kind ("h3f2a9c41"), stable across
/// renames, so references between hosts, snippets and keys survive edits.
/// Raw-value types, so each is a plain string in the file.
public protocol VaultID: RawRepresentable, Hashable, Codable, Sendable, Comparable, CustomStringConvertible
where RawValue == String {
    static var prefix: Character { get }
    init(rawValue: String)
}

extension VaultID {
    /// A new id: the kind's letter and eight random hex digits.
    public static func make() -> Self {
        let digits = String(UInt32.random(in: .min ... .max), radix: 16)
        return Self(rawValue: String(prefix) + String(repeating: "0", count: 8 - digits.count) + digits)
    }

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
    public var description: String { rawValue }
}

public struct HostID: VaultID {
    public static let prefix: Character = "h"
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
}

public struct GroupID: VaultID {
    public static let prefix: Character = "g"
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
}

public struct SnippetID: VaultID {
    public static let prefix: Character = "s"
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
}

public struct KeyID: VaultID {
    public static let prefix: Character = "k"
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
}

public struct TunnelID: VaultID {
    public static let prefix: Character = "t"
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
}

// MARK: - Hosts

/// A saved host: either one WRLD describes itself, or a name from `~/.ssh/config` that WRLD
/// only refers to, so your own config keeps deciding how to reach it.
public struct WRLDHost: Equatable, Sendable, Identifiable {
    public enum Source: Equatable, Sendable {
        case wrld(Connection)
        case sshConfig(alias: String)
    }

    public var id: HostID
    /// What WRLD shows: "prod-api".
    public var name: String
    public var source: Source
    public var groupID: GroupID?
    public var tags: [String]
    /// Pinned to Legends, at the top of the sidebar.
    public var isLegend: Bool
    public var tunnels: [Tunnel]
    /// Typed into each new session once it starts ("tmux new -A -s main").
    public var onConnectSnippetID: SnippetID?

    public init(
        id: HostID = .make(), name: String, source: Source, groupID: GroupID? = nil, tags: [String] = [],
        isLegend: Bool = false, tunnels: [Tunnel] = [], onConnectSnippetID: SnippetID? = nil
    ) {
        self.id = id
        self.name = name
        self.source = source
        self.groupID = groupID
        self.tags = tags
        self.isLegend = isLegend
        self.tunnels = tunnels
        self.onConnectSnippetID = onConnectSnippetID
    }

    public var connection: Connection? {
        if case .wrld(let connection) = source { return connection }
        return nil
    }

    public var sshConfigAlias: String? {
        if case .sshConfig(let alias) = source { return alias }
        return nil
    }
}

/// How to reach a host WRLD describes itself.
public struct Connection: Equatable, Sendable {
    public enum Identity: Equatable, Sendable {
        /// Whatever ssh would try: the agent and your default keys.
        case automatic
        /// A key in this Mac's Secure Enclave, asking for Touch ID on each login.
        case secureEnclave(KeyID)
        /// A private key file, "~/.ssh/id_ed25519".
        case keyFile(String)
    }

    /// A name or address: "10.0.4.21", "nas.local".
    public var address: String
    /// Nil: ssh's default (your user name, or your config's).
    public var user: String?
    /// Nil: 22, or your config's.
    public var port: Int?
    public var identity: Identity
    /// Reached through another saved host (ProxyJump).
    public var jumpHostID: HostID?
    public var forwardAgent: Bool

    public init(
        address: String, user: String? = nil, port: Int? = nil, identity: Identity = .automatic,
        jumpHostID: HostID? = nil, forwardAgent: Bool = false
    ) {
        self.address = address
        self.user = user
        self.port = port
        self.identity = identity
        self.jumpHostID = jumpHostID
        self.forwardAgent = forwardAgent
    }
}

public struct Group: Equatable, Sendable, Identifiable, Codable {
    public var id: GroupID
    public var name: String

    public init(id: GroupID = .make(), name: String) {
        self.id = id
        self.name = name
    }
}

/// A saved command, with `{{placeholders}}` (`SnippetTemplate`).
public struct Snippet: Equatable, Sendable, Identifiable, Codable {
    public var id: SnippetID
    public var name: String
    public var text: String

    public init(id: SnippetID = .make(), name: String, text: String) {
        self.id = id
        self.name = name
        self.text = text
    }

    public var template: SnippetTemplate { SnippetTemplate(text) }
}

/// A key WRLD knows about. For a Secure Enclave key, `handle` is the file ssh reads: a
/// reference to the key in the Secure Enclave, not the key itself.
public struct Key: Equatable, Sendable, Identifiable, Codable {
    public enum Kind: String, Codable, Sendable {
        case secureEnclave
        case file
    }

    public var id: KeyID
    public var kind: Kind
    public var label: String
    /// The file ssh is given as `IdentityFile`.
    public var handle: String
    /// The public key, as `authorized_keys` takes it.
    public var publicKey: String

    public init(id: KeyID = .make(), kind: Kind, label: String, handle: String, publicKey: String) {
        self.id = id
        self.kind = kind
        self.label = label
        self.handle = handle
        self.publicKey = publicKey
    }
}

/// A port forward that belongs to a host (Come & Go).
public struct Tunnel: Equatable, Sendable, Identifiable {
    public var id: TunnelID
    public var spec: TunnelSpec
    /// Opened whenever the host connects; otherwise only when turned on.
    public var opensWithConnection: Bool

    public init(id: TunnelID = .make(), spec: TunnelSpec, opensWithConnection: Bool = false) {
        self.id = id
        self.spec = spec
        self.opensWithConnection = opensWithConnection
    }
}

/// A host to connect to: one in WRLD, or a name found in `~/.ssh/config` that WRLD doesn't
/// hold (Hear Me Calling lists those too).
public enum HostRef: Hashable, Sendable {
    case vault(HostID)
    case sshConfig(alias: String)
}

// MARK: - The file's shape

extension Vault: Codable {
    private enum CodingKeys: String, CodingKey {
        case version, hosts, groups, snippets, keys
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decodeIfPresent(Int.self, forKey: .version) ?? 1
        hosts = try container.decodeIfPresent([WRLDHost].self, forKey: .hosts) ?? []
        groups = try container.decodeIfPresent([Group].self, forKey: .groups) ?? []
        snippets = try container.decodeIfPresent([Snippet].self, forKey: .snippets) ?? []
        keys = try container.decodeIfPresent([Key].self, forKey: .keys) ?? []
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(version, forKey: .version)
        try container.encode(hosts, forKey: .hosts)
        try container.encode(groups, forKey: .groups)
        try container.encode(snippets, forKey: .snippets)
        try container.encode(keys, forKey: .keys)
    }
}

/// A host is flat in the file: an `address` (with `user`, `port`, `identity`, `jumpHost`)
/// for one WRLD describes, or an `sshConfigAlias`.
extension WRLDHost: Codable {
    private enum CodingKeys: String, CodingKey {
        case id, name, address, user, port, identity, jumpHost, forwardAgent, sshConfigAlias
        case group, tags, legend, tunnels, onConnect
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(HostID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        if let alias = try container.decodeIfPresent(String.self, forKey: .sshConfigAlias) {
            source = .sshConfig(alias: alias)
        } else {
            source = .wrld(
                Connection(
                    address: try container.decode(String.self, forKey: .address),
                    user: try container.decodeIfPresent(String.self, forKey: .user),
                    port: try container.decodeIfPresent(Int.self, forKey: .port),
                    identity: try container.decodeIfPresent(Connection.Identity.self, forKey: .identity)
                        ?? .automatic,
                    jumpHostID: try container.decodeIfPresent(HostID.self, forKey: .jumpHost),
                    forwardAgent: try container.decodeIfPresent(Bool.self, forKey: .forwardAgent) ?? false))
        }
        groupID = try container.decodeIfPresent(GroupID.self, forKey: .group)
        tags = try container.decodeIfPresent([String].self, forKey: .tags) ?? []
        isLegend = try container.decodeIfPresent(Bool.self, forKey: .legend) ?? false
        tunnels = try container.decodeIfPresent([Tunnel].self, forKey: .tunnels) ?? []
        onConnectSnippetID = try container.decodeIfPresent(SnippetID.self, forKey: .onConnect)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        switch source {
        case .wrld(let connection):
            try container.encode(connection.address, forKey: .address)
            try container.encodeIfPresent(connection.user, forKey: .user)
            try container.encodeIfPresent(connection.port, forKey: .port)
            if connection.identity != .automatic { try container.encode(connection.identity, forKey: .identity) }
            try container.encodeIfPresent(connection.jumpHostID, forKey: .jumpHost)
            if connection.forwardAgent { try container.encode(true, forKey: .forwardAgent) }
        case .sshConfig(let alias):
            try container.encode(alias, forKey: .sshConfigAlias)
        }
        try container.encodeIfPresent(groupID, forKey: .group)
        if !tags.isEmpty { try container.encode(tags, forKey: .tags) }
        if isLegend { try container.encode(true, forKey: .legend) }
        if !tunnels.isEmpty { try container.encode(tunnels, forKey: .tunnels) }
        try container.encodeIfPresent(onConnectSnippetID, forKey: .onConnect)
    }
}

/// `"automatic"`, `{"secureEnclave": "k…"}` or `{"keyFile": "~/.ssh/id_ed25519"}`.
extension Connection.Identity: Codable {
    private enum CodingKeys: String, CodingKey {
        case secureEnclave, keyFile
    }

    public init(from decoder: any Decoder) throws {
        if let word = try? decoder.singleValueContainer().decode(String.self) {
            guard word == "automatic" else {
                throw DecodingError.dataCorrupted(
                    .init(codingPath: decoder.codingPath, debugDescription: "Unknown identity \"\(word)\""))
            }
            self = .automatic
            return
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let key = try container.decodeIfPresent(KeyID.self, forKey: .secureEnclave) {
            self = .secureEnclave(key)
        } else if let path = try container.decodeIfPresent(String.self, forKey: .keyFile) {
            self = .keyFile(path)
        } else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: "An identity needs secureEnclave or keyFile"))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        switch self {
        case .automatic:
            var container = encoder.singleValueContainer()
            try container.encode("automatic")
        case .secureEnclave(let key):
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(key, forKey: .secureEnclave)
        case .keyFile(let path):
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(path, forKey: .keyFile)
        }
    }
}
