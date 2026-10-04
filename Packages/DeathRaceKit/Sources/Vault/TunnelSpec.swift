/// One port forward, as `ssh -L`, `-R` or `-D` takes it (Come & Go).
public struct TunnelSpec: Equatable, Sendable {
    public enum Kind: String, Codable, Sendable, CaseIterable {
        /// A port on this Mac reaches a host the server can reach (`-L`).
        case local
        /// A port on the server reaches a host this Mac can reach (`-R`).
        case remote
        /// A SOCKS proxy on this Mac that goes out through the server (`-D`).
        case dynamic
    }

    public enum Problem: Error, Equatable, Sendable {
        case port(String)
        case host(String)
        case missingTarget
    }

    public var kind: Kind
    /// Where it listens; nil for ssh's default, the loopback address.
    public var bindAddress: String?
    public var listenPort: Int
    /// Where it forwards to; nil for a dynamic forward.
    public var target: Endpoint?

    public struct Endpoint: Equatable, Sendable {
        public var host: String
        public var port: Int

        public init(host: String, port: Int) {
            self.host = host
            self.port = port
        }
    }

    public init(kind: Kind, bindAddress: String? = nil, listenPort: Int, target: Endpoint? = nil) {
        self.kind = kind
        self.bindAddress = bindAddress
        self.listenPort = listenPort
        self.target = target
    }

    /// From the add form's fields: "Listen on" ("5432", "127.0.0.1:5432") and "Forward to"
    /// ("db:5432", "[::1]:80"), which a dynamic forward doesn't have.
    public static func parse(kind: Kind, listen: String, forwardTo: String = "") throws(Problem) -> TunnelSpec {
        let listenText = listen.trimmingSpaces
        var bindAddress: String?
        let listenPort: Int
        if let split = splitHostPort(listenText) {
            bindAddress = split.host
            listenPort = try port(split.port)
        } else {
            listenPort = try port(listenText)
        }
        if let bindAddress { try checkHost(bindAddress) }
        var spec = TunnelSpec(kind: kind, bindAddress: bindAddress, listenPort: listenPort)
        if kind != .dynamic {
            guard let split = splitHostPort(forwardTo.trimmingSpaces) else { throw .missingTarget }
            try checkHost(split.host)
            spec.target = Endpoint(host: split.host, port: try port(split.port))
        }
        return spec
    }

    /// Everything that would stop ssh taking it, or let it smuggle in another option.
    public var problems: [Problem] {
        var problems: [Problem] = []
        if !(1...65_535).contains(listenPort) { problems.append(.port(String(listenPort))) }
        if let bindAddress, (try? Self.checkHost(bindAddress)) == nil { problems.append(.host(bindAddress)) }
        if kind == .dynamic { return problems }
        guard let target else { return problems + [.missingTarget] }
        if (try? Self.checkHost(target.host)) == nil { problems.append(.host(target.host)) }
        if !(1...65_535).contains(target.port) { problems.append(.port(String(target.port))) }
        return problems
    }

    public var flag: String {
        switch kind {
        case .local: "-L"
        case .remote: "-R"
        case .dynamic: "-D"
        }
    }

    /// The argument after `flag`: `[bind:]port:host:hostport`, or `[bind:]port`.
    public var argument: String {
        var parts: [String] = []
        if let bindAddress { parts.append(Self.bracketed(bindAddress)) }
        parts.append(String(listenPort))
        if let target, kind != .dynamic {
            parts.append(Self.bracketed(target.host))
            parts.append(String(target.port))
        }
        return parts.joined(separator: ":")
    }

    /// "Listen on", as the form shows it.
    public var listenText: String {
        bindAddress.map { "\(Self.bracketed($0)):\(listenPort)" } ?? String(listenPort)
    }

    /// "Forward to", as the form shows it; empty for a dynamic forward.
    public var targetText: String {
        target.map { "\(Self.bracketed($0.host)):\($0.port)" } ?? ""
    }

    /// The Come & Go board's line: "5432 → db:5432 · Local · through prod-api", with "on"
    /// when the target is the host itself ("8080 → localhost:3000 · Local · on nas-999").
    public func summary(host: String) -> String {
        switch kind {
        case .local:
            let via = target.map { Self.isLoopback($0.host) } == true ? "on" : "through"
            return "\(listenText) → \(targetText) · Local · \(via) \(host)"
        case .remote:
            return "\(listenText) on \(host) → \(targetText) · Remote"
        case .dynamic:
            return "SOCKS \(listenText) · Dynamic · through \(host)"
        }
    }

    // MARK: - Pieces

    static func isLoopback(_ host: String) -> Bool {
        ["localhost", "127.0.0.1", "::1"].contains(host.lowercased())
    }

    static func bracketed(_ host: String) -> String {
        host.contains(":") ? "[\(host)]" : host
    }

    /// "host:port" or "[v6]:port"; nil when there's no host part.
    static func splitHostPort(_ text: String) -> (host: String, port: String)? {
        if text.hasPrefix("["), let close = text.firstIndex(of: "]") {
            let host = String(text[text.index(after: text.startIndex)..<close])
            let rest = text[text.index(after: close)...]
            guard rest.hasPrefix(":"), !host.isEmpty else { return nil }
            return (host, String(rest.dropFirst()))
        }
        guard let colon = text.lastIndex(of: ":"), !text[..<colon].contains(":") else { return nil }
        let host = String(text[..<colon])
        return host.isEmpty ? nil : (host, String(text[text.index(after: colon)...]))
    }

    static func port(_ text: String) throws(Problem) -> Int {
        guard !text.isEmpty, text.count <= 5, text.allSatisfy({ $0.isASCII && $0.isNumber }), let port = Int(text),
            (1...65_535).contains(port)
        else { throw .port(text) }
        return port
    }

    /// Names, IPv4 and IPv6 addresses only: nothing ssh's option parser or a shell would
    /// read as more than a host.
    static func checkHost(_ host: String) throws(Problem) {
        let allowed = { (c: Character) -> Bool in
            c.isASCII && (c.isLetter || c.isNumber || c == "." || c == "-" || c == "_" || c == ":" || c == "%")
        }
        guard !host.isEmpty, host.count <= 253, host.allSatisfy(allowed), !host.hasPrefix("-") else {
            throw .host(host)
        }
    }
}

/// A tunnel is flat in the file: `{"id", "kind", "listen", "target", "opensWithConnection"}`.
extension Tunnel: Codable {
    private enum CodingKeys: String, CodingKey {
        case id, kind, listen, target, opensWithConnection
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(TunnelID.self, forKey: .id)
        let kind = try container.decode(TunnelSpec.Kind.self, forKey: .kind)
        let listen = try container.decode(String.self, forKey: .listen)
        let target = try container.decodeIfPresent(String.self, forKey: .target) ?? ""
        do {
            spec = try TunnelSpec.parse(kind: kind, listen: listen, forwardTo: target)
        } catch {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: "Tunnel \(id): \(error)"))
        }
        opensWithConnection = try container.decodeIfPresent(Bool.self, forKey: .opensWithConnection) ?? false
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(spec.kind, forKey: .kind)
        try container.encode(spec.listenText, forKey: .listen)
        if spec.kind != .dynamic { try container.encode(spec.targetText, forKey: .target) }
        if opensWithConnection { try container.encode(true, forKey: .opensWithConnection) }
    }
}
