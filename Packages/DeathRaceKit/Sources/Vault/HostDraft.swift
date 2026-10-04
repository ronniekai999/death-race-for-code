/// What ssh_config can hold safely, shared by the New Host sheet and the config WRLD writes,
/// so a host the sheet accepts is never one the config refuses.
public enum SSHValue {
    /// One word with nothing ssh_config or a shell would read as more: no spaces, quotes,
    /// comments, control characters or percent tokens.
    public static func isWord(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 255
            && value.unicodeScalars.allSatisfy { scalar in
                scalar.value > 0x20 && scalar.value != 0x7F && !"\"'#%\\".unicodeScalars.contains(scalar)
                    && !(0x80...0x9F).contains(scalar.value)
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
        guard SSHValue.isWord(address), !address.hasPrefix("-") else { throw .address }
        let user = trimmed(self.user)
        guard user.isEmpty || (SSHValue.isWord(user) && !user.hasPrefix("-")) else { throw .user }
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

    private func trimmed(_ text: String) -> String {
        var result = Substring(text)
        while result.first?.isWhitespace == true { result = result.dropFirst() }
        while result.last?.isWhitespace == true { result = result.dropLast() }
        return String(result)
    }
}
