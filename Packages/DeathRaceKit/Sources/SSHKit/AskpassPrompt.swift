import Foundation

/// What ssh asks through askpass, recognized from the words ssh writes itself.
///
/// The broker answers from the Keychain only a prompt it recognizes for the hop it holds a
/// secret for. ProxyJump's hops share one askpass, so this matching is what keeps the jump
/// server from ever receiving the target's password. Anything it doesn't recognize is put
/// to you as asked, and never answered from the Keychain.
public struct AskpassPrompt: Equatable, Sendable {
    /// A user on a host, as ssh names them in its prompts: `HostKeyAlias` when set, else the
    /// host name it connected to.
    public struct Hop: Hashable, Sendable {
        public var user: String
        public var host: String

        public init(user: String, host: String) {
            self.user = user
            self.host = host
        }
    }

    public enum Kind: Equatable, Sendable {
        /// `ubuntu@10.0.4.21's password: `: password authentication.
        case password(Hop)
        /// `(ubuntu@10.0.4.21) Password: `: a keyboard-interactive question; `question` is the
        /// server's own text.
        case keyboardInteractive(Hop, question: String)
        /// `Enter passphrase for key '/Users/r/.ssh/id_ed25519': `
        case passphrase(keyFile: String)
        /// `Enter PIN for authenticator: `
        case pin
        /// `The authenticity of host '…' can't be established. … fingerprint is SHA256:…`
        case newHostKey(host: String, keyType: String?, fingerprint: String?)
        /// `SSH_ASKPASS_PROMPT=none`: something ssh shows while it waits, such as "Confirm user
        /// presence for key ECDSA-SK …" while Touch ID asks.
        case notice(String)
        /// `SSH_ASKPASS_PROMPT=confirm`, or another yes-or-no question.
        case confirmation(String)
        /// Anything else, shown as it is.
        case other(String)
    }

    public let text: String
    /// `SSH_ASKPASS_PROMPT`, as ssh set it.
    public let hint: String?
    public let kind: Kind

    public init(text: String, hint: String? = nil) {
        self.text = text
        self.hint = hint
        kind = Self.classify(text, hint: hint)
    }

    /// Whether the answer is typed hidden.
    public var isSecret: Bool {
        switch kind {
        case .password, .keyboardInteractive, .passphrase, .pin: true
        case .newHostKey, .notice, .confirmation, .other: false
        }
    }

    /// Whether this is ssh asking for `hop`'s password: password authentication for that
    /// user and host, or a keyboard-interactive question that asks for a password. Older
    /// ssh cut the user to 30 characters and the host to 128.
    public func asksForPassword(of hop: Hop) -> Bool {
        switch kind {
        case .password(let asked):
            return Self.same(asked, hop)
        case .keyboardInteractive(let asked, let question):
            return Self.same(asked, hop) && question.lowercased().contains("password")
        default:
            return false
        }
    }

    /// Whether this asks for the passphrase of the key file at `path`.
    public func asksForPassphrase(of path: String) -> Bool {
        if case .passphrase(let file) = kind { return file == path }
        return false
    }

    static func same(_ asked: Hop, _ hop: Hop) -> Bool {
        func matches(_ written: String, _ expected: String, cut: Int) -> Bool {
            written == expected || (written.count == cut && expected.count > cut && expected.hasPrefix(written))
        }
        return matches(asked.user, hop.user, cut: 30) && matches(asked.host, hop.host, cut: 128)
    }

    // MARK: - Recognizing

    static func classify(_ text: String, hint: String?) -> Kind {
        switch hint {
        case "none": return .notice(text)
        case "confirm": return .confirmation(text)
        default: break
        }
        if let hostKey = newHostKey(text) { return hostKey }
        if text.hasPrefix("Enter passphrase for key '"),
            let path = between(text, after: "Enter passphrase for key '", before: "'")
        {
            return .passphrase(keyFile: path)
        }
        if text.hasPrefix("Enter PIN for ") { return .pin }
        if text.hasPrefix("("), let close = text.firstIndex(of: ")"),
            let hop = hop(String(text[text.index(after: text.startIndex)..<close])),
            text[text.index(after: close)...].hasPrefix(" ")
        {
            let question = String(text[text.index(close, offsetBy: 2)...])
            return .keyboardInteractive(hop, question: question)
        }
        let trimmed = text.hasSuffix(" ") ? String(text.dropLast()) : text
        if trimmed.hasSuffix("'s password:"), !text.hasPrefix("Enter "), !text.hasPrefix("Retype "),
            let hop = hop(String(trimmed.dropLast("'s password:".count)))
        {
            return .password(hop)
        }
        if text.contains("(yes/no") { return .confirmation(text) }
        return .other(text)
    }

    /// "user@host", split at the last `@`: a user name may hold one, a host name can't.
    static func hop(_ text: String) -> Hop? {
        guard let at = text.lastIndex(of: "@") else { return nil }
        let user = String(text[..<at])
        let host = String(text[text.index(after: at)...])
        guard !user.isEmpty, !host.isEmpty, !host.contains(" "), !user.contains("\n") else { return nil }
        return Hop(user: user, host: host)
    }

    static func newHostKey(_ text: String) -> Kind? {
        guard text.contains("The authenticity of host '") else { return nil }
        var host = between(text, after: "The authenticity of host '", before: "'") ?? ""
        // "prod-api (10.0.4.21)": the name as typed, then the address.
        if let paren = host.range(of: " (") { host = String(host[..<paren.lowerBound]) }
        var keyType: String?
        var fingerprint: String?
        if let marker = text.range(of: " key fingerprint is ") {
            keyType = text[..<marker.lowerBound].split(whereSeparator: { $0 == " " || $0 == "\n" }).last.map(
                String.init)
            let rest = text[marker.upperBound...]
            let end = rest.firstIndex(where: { $0 == "\n" || $0 == " " }) ?? rest.endIndex
            var print = String(rest[..<end])
            if print.hasSuffix(".") { print.removeLast() }
            fingerprint = print.isEmpty ? nil : print
        }
        return .newHostKey(host: host, keyType: keyType, fingerprint: fingerprint)
    }

    static func between(_ text: String, after start: String, before end: Character) -> String? {
        guard let range = text.range(of: start) else { return nil }
        let rest = text[range.upperBound...]
        guard let close = rest.firstIndex(of: end) else { return nil }
        return String(rest[..<close])
    }
}
