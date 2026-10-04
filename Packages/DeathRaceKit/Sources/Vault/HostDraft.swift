/// What ssh_config can hold safely, shared by the New Host sheet and the config WRLD writes,
/// so a host the sheet accepts is never one the config refuses.
public enum SSHValue {
    /// A host name, IP address or `~/.ssh/config` alias safe to place in the generated
    /// config — including as a `ProxyJump` value, which OpenSSH runs through `/bin/sh`, and
    /// as the destination argument to `ssh`. An allow-list: letters, digits and only the
    /// punctuation host names, bracketed IPv6 literals and `user@host:port` aliases need.
    /// So `$( ) ` \ ; | & { } < > * ? !`, spaces, quotes, `#`, `%` and control characters
    /// are all refused, as is a leading `-` (which `ssh` would read as an option).
    public static func isHostName(_ value: String) -> Bool {
        guard !value.isEmpty, value.utf8.count <= 255, !value.hasPrefix("-") else { return false }
        return value.unicodeScalars.allSatisfy { scalar in
            switch scalar {
            case "A"..."Z", "a"..."z", "0"..."9": true
            default: ".-_:@[]".unicodeScalars.contains(scalar)
            }
        }
    }

    /// A user name safe to place after `User` and to reach `%r`: letters, digits, `.`, `-`,
    /// `_` and `@` (for identity-provider logins). No leading `-`, and none of the shell or
    /// ssh_config characters `isHostName` refuses.
    public static func isUserName(_ value: String) -> Bool {
        guard !value.isEmpty, value.utf8.count <= 255, !value.hasPrefix("-") else { return false }
        return value.unicodeScalars.allSatisfy { scalar in
            switch scalar {
            case "A"..."Z", "a"..."z", "0"..."9": true
            default: ".-_@".unicodeScalars.contains(scalar)
            }
        }
    }

    /// A path ssh can be given: no control characters or double quotes (spaces are quoted).
    public static func isPath(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 1_024
            && value.unicodeScalars.allSatisfy { scalar in
                scalar.value >= 0x20 && scalar.value != 0x7F && scalar != "\"" && !(0x80...0x9F).contains(scalar.value)
            }
    }
}

/// The New Host sheet's fields, as typed, until they make a host.
public struct HostDraft: Equatable, Sendable {
    /// How the host signs you in.
    public enum SignIn: Equatable, Sendable {
        /// Whatever ssh would do: your agent, your keys, then a password.
        case automatic
        /// A new key in this Mac's Secure Enclave, with Touch ID. The host logs in as usual
        /// until the key is on the server, which happens over that first connection.
        case newSecureEnclaveKey
        /// A Secure Enclave key WRLD already holds.
        case secureEnclaveKey(KeyID)
        case keyFile(String)
    }

    public enum Problem: Error, Equatable, Sendable {
        case noAddress
        case address
        case user
        case port
        case keyFile

        /// What the sheet says under the field.
        public var sentence: String {
            switch self {
            case .noAddress: "Enter the server’s name or IP address."
            case .address: "That isn’t a host name or an IP address."
            case .user: "A user name has no spaces or quotes."
            case .port: "A port is a number from 1 to 65535."
            case .keyFile: "Choose the key file to sign in with."
            }
        }
    }

    public var name = ""
    public var address = ""
    public var user = ""
    public var port = ""
    public var jumpHostID: HostID?
    public var signIn = SignIn.automatic

    public init(
        name: String = "", address: String = "", user: String = "", port: String = "", jumpHostID: HostID? = nil,
        signIn: SignIn = .automatic
    ) {
        self.name = name
        self.address = address
        self.user = user
        self.port = port
        self.jumpHostID = jumpHostID
        self.signIn = signIn
    }

    /// The host these fields describe, or the first thing wrong with them. Spaces around
    /// what was typed don't count; a blank name takes the address. A new Secure Enclave key
    /// isn't the host's yet: it signs in as usual until the key is on the server.
    public func host(id: HostID = .make()) throws(Problem) -> WRLDHost {
        let address = trimmed(self.address)
        guard !address.isEmpty else { throw .noAddress }
        guard SSHValue.isHostName(address) else { throw .address }
        let user = trimmed(self.user)
        guard user.isEmpty || SSHValue.isUserName(user) else { throw .user }
        let portText = trimmed(self.port)
        let port: Int?
        if portText.isEmpty {
            port = nil
        } else {
            guard portText.allSatisfy(\.isASCII), let number = Int(portText), (1...65_535).contains(number) else {
                throw .port
            }
            port = number
        }
        let identity: Connection.Identity
        switch signIn {
        case .automatic, .newSecureEnclaveKey:
            identity = .automatic
        case .secureEnclaveKey(let key):
            identity = .secureEnclave(key)
        case .keyFile(let path):
            let path = trimmed(path)
            guard SSHValue.isPath(path) else { throw .keyFile }
            identity = .keyFile(path)
        }
        let name = trimmed(self.name)
        return WRLDHost(
            id: id, name: name.isEmpty ? address : name,
            source: .wrld(
                Connection(
                    address: address, user: user.isEmpty ? nil : user, port: port, identity: identity,
                    jumpHostID: jumpHostID)))
    }

    /// The fields of a host WRLD describes itself, for the inspector; nil for one from
    /// `~/.ssh/config`, which that file describes.
    public init?(editing host: WRLDHost) {
        guard let connection = host.connection else { return nil }
        let signIn: SignIn =
            switch connection.identity {
            case .automatic: .automatic
            case .secureEnclave(let key): .secureEnclaveKey(key)
            case .keyFile(let path): .keyFile(path)
            }
        self.init(
            name: host.name, address: connection.address, user: connection.user ?? "",
            port: connection.port.map(String.init) ?? "", jumpHostID: connection.jumpHostID, signIn: signIn)
    }

    /// `host` with these fields: its name and how it's reached change, and everything else
    /// about it (group, tags, Legend, tunnels, what it runs on connect, agent forwarding)
    /// stays.
    public func applied(to host: WRLDHost) throws(Problem) -> WRLDHost {
        let edited = try self.host(id: host.id)
        var result = host
        result.name = edited.name
        guard case .wrld(var connection) = edited.source else { return result }
        connection.forwardAgent = host.connection?.forwardAgent ?? false
        result.source = .wrld(connection)
        return result
    }

    private func trimmed(_ text: String) -> String {
        var result = Substring(text)
        while result.first?.isWhitespace == true { result = result.dropFirst() }
        while result.last?.isWhitespace == true { result = result.dropLast() }
        return String(result)
    }
}
