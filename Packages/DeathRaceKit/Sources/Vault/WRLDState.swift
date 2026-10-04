import Foundation

/// What WRLD learns as it's used, kept apart from `wrld.json` so that file changes only
/// when you change it: when each host was last reached, what it runs, how quickly it
/// answered, how often each snippet is used, and which `~/.ssh/config` hosts you didn't
/// want offered again. `~/.deathrace/state.json`.
///
/// It's a cache: a file that can't be read is the same as none.
public struct WRLDState: Equatable, Sendable, Codable {
    public static let formatVersion = 1

    /// What WRLD knows of one host.
    public struct HostFacts: Equatable, Sendable, Codable {
        /// The last time a connection to it came up.
        public var lastConnected: Date?
        /// "Ubuntu 24.04", from its `/etc/os-release`, and when that was read.
        public var os: String?
        public var osReadAt: Date?
        /// How long a TCP connection took at the last check, in milliseconds; nil when it
        /// didn't answer. Nil `latencyCheckedAt` means it was never checked.
        public var latency: Int?
        public var latencyCheckedAt: Date?

        public init(
            lastConnected: Date? = nil, os: String? = nil, osReadAt: Date? = nil, latency: Int? = nil,
            latencyCheckedAt: Date? = nil
        ) {
            self.lastConnected = lastConnected
            self.os = os
            self.osReadAt = osReadAt
            self.latency = latency
            self.latencyCheckedAt = latencyCheckedAt
        }

        /// The last check got no answer.
        public var isSilent: Bool { latencyCheckedAt != nil && latency == nil }
    }

    public var version: Int
    /// By `key(for:)`.
    public var hosts: [String: HostFacts]
    /// How many times each snippet was typed in, by its id.
    public var snippetUses: [String: Int]
    /// `~/.ssh/config` names whose "Add to WRLD" offer was put away; a name not among them
    /// brings it back.
    public var dismissedImports: [String]

    public init(
        hosts: [String: HostFacts] = [:], snippetUses: [String: Int] = [:], dismissedImports: [String] = []
    ) {
        version = Self.formatVersion
        self.hosts = hosts
        self.snippetUses = snippetUses
        self.dismissedImports = dismissedImports
    }

    /// A host's key: its id, or `alias:` and its name in `~/.ssh/config`, as its control
    /// socket is named.
    public static func key(for host: HostRef) -> String {
        switch host {
        case .vault(let id): id.rawValue
        case .sshConfig(let alias): "alias:" + alias
        }
    }

    public func facts(_ host: HostRef) -> HostFacts { hosts[Self.key(for: host)] ?? HostFacts() }

    public mutating func update(_ host: HostRef, _ change: (inout HostFacts) -> Void) {
        var facts = facts(host)
        change(&facts)
        hosts[Self.key(for: host)] = facts
    }

    public func uses(of snippet: SnippetID) -> Int { snippetUses[snippet.rawValue] ?? 0 }

    public mutating func used(_ snippet: SnippetID) {
        snippetUses[snippet.rawValue, default: 0] += 1
    }

    private enum CodingKeys: String, CodingKey {
        case version, hosts, snippetUses, dismissedImports
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decodeIfPresent(Int.self, forKey: .version) ?? Self.formatVersion
        hosts = try container.decodeIfPresent([String: HostFacts].self, forKey: .hosts) ?? [:]
        snippetUses = try container.decodeIfPresent([String: Int].self, forKey: .snippetUses) ?? [:]
        dismissedImports = try container.decodeIfPresent([String].self, forKey: .dismissedImports) ?? []
    }
}

/// Reads and writes `WRLDState`, at `path`.
public struct WRLDStateStore: Sendable {
    public let path: String

    public init(path: String) {
        self.path = path
    }

    /// The state; empty when there is no file, or one that can't be read.
    public func load() -> WRLDState {
        guard let bytes = try? AtomicFile.read(path),
            let state = try? Self.decoder.decode(WRLDState.self, from: Data(bytes)),
            state.version <= WRLDState.formatVersion
        else { return WRLDState() }
        return state
    }

    /// Writes `state` (0600, all at once). A file from a newer build is left alone.
    public func save(_ state: WRLDState) throws {
        if let bytes = try AtomicFile.read(path),
            let existing = try? Self.decoder.decode(WRLDState.self, from: Data(bytes)),
            existing.version > WRLDState.formatVersion
        {
            return
        }
        let data = try Self.encoder.encode(state)
        try AtomicFile.write(Array(data), to: path)
    }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
