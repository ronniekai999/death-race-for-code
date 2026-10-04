import Foundation

/// Why a connection failed, read from what its master wrote on stderr.
public enum ConnectionFailure: Equatable, Sendable {
    /// "Permission denied (publickey,password)."
    case authenticationFailed(methods: [String])
    /// "Too many authentication failures": every key the agent offered was refused.
    case tooManyAuthenticationFailures
    /// "No route to host": unreachable, or Local Network privacy refusing it.
    case noRoute
    /// "Network is unreachable".
    case networkUnreachable
    /// "Connection refused".
    case refused
    /// "Operation timed out" / "Connection timed out".
    case timedOut
    /// "Could not resolve hostname …".
    case unknownHost
    /// "REMOTE HOST IDENTIFICATION HAS CHANGED": the key ssh was sent isn't the one
    /// known_hosts holds, with the line holding the old one ("…/known_hosts:3"), and how
    /// ssh says to forget it.
    case hostKeyChanged(fingerprint: String?, knownHostsLine: String?, removal: KeyRemoval? = nil)
    /// "Host key verification failed." for any other reason (you said no, say).
    case hostKeyRejected
    /// "Connection closed by …", "Connection reset by peer".
    case closedByRemote
    /// Ended by the app: a prompt was cancelled or Touch ID declined.
    case cancelled
    /// Anything else: the last line ssh wrote.
    case other(String)

    /// The sentence a pane shows, for `host` as WRLD names it.
    public func sentence(host: String) -> String {
        switch self {
        case .authenticationFailed(let methods):
            let accepted = methods.compactMap(Self.methodName).joined(separator: ", ")
            return accepted.isEmpty
                ? "\(host) didn't accept the login."
                : "\(host) didn't accept the login. It takes: \(accepted)."
        case .tooManyAuthenticationFailures:
            return "\(host) stopped after too many keys were tried. Choose one key for it in WRLD."
        case .noRoute: return "There's no route to \(host)."
        case .networkUnreachable: return "The network isn't reachable."
        case .refused: return "\(host) refused the connection."
        case .timedOut: return "\(host) didn't answer."
        case .unknownHost: return "\(host)'s address couldn't be found."
        case .hostKeyChanged:
            return
                "\(host)'s host key has changed. It may have been reinstalled, or someone may be in between. Death Race didn't connect."
        case .hostKeyRejected: return "\(host)'s host key wasn't trusted, so Death Race didn't connect."
        case .closedByRemote: return "\(host) closed the connection."
        case .cancelled: return "Connecting to \(host) was cancelled."
        case .other(let line): return "The connection to \(host) ended: \(line)"
        }
    }

    static func methodName(_ method: String) -> String? {
        switch method {
        case "publickey": "a key"
        case "password": "a password"
        case "keyboard-interactive": "questions"
        case "gssapi-with-mic", "gssapi-keyex": "Kerberos"
        case "hostbased": nil
        default: method
        }
    }
}

/// What a pane that couldn't connect offers next, as buttons.
public enum ConnectionOffer: Equatable, Sendable {
    /// Try again.
    case reconnect
    /// ssh in the pane itself, logging in on its own, without the app's master.
    case plainSSH
    /// macOS's Local Network setting, where Death Race is allowed or not.
    case allowLocalNetwork
    /// After a host's key changed: forget the old one, once you've checked the new one.
    case forgetHostKey
}

/// What `ssh-keygen -R` needs to forget a host's key: the file and the name the key is
/// filed under, as ssh's own message says to run it.
public struct KeyRemoval: Equatable, Sendable {
    public var file: String
    public var name: String

    public init(file: String, name: String) {
        self.file = file
        self.name = name
    }

    /// Whether this removal, read from ssh's stderr, names a host and a file that `ssh -G`
    /// confirms for the connection we actually made. A server can print a convincing
    /// changed-key warning in its own banner (naming any host and any absolute file), so the
    /// file and name are trusted only when they match one of the connection's own hops:
    /// otherwise forgetting would remove another host's pinned key, or rewrite another file.
    /// `hops` is each hop's `knownHostsName` and its `userKnownHostsFiles`, from `ssh -G`.
    public func isConfirmed(by hops: [(name: String?, files: [String])]) -> Bool {
        hops.contains { hop in hop.name == name && hop.files.contains(file) }
    }

    /// From ssh's "remove with:" line: `ssh-keygen -f '/Users/r/.ssh/known_hosts' -R
    /// '[10.0.4.21]:2222'`, single or double quotes.
    public init?(parsing line: String) {
        let words = Self.words(line)
        guard let keygen = words.firstIndex(where: { $0.hasSuffix("ssh-keygen") }) else { return nil }
        var file: String?
        var name: String?
        var index = keygen + 1
        while index + 1 < words.count {
            switch words[index] {
            case "-f": file = words[index + 1]
            case "-R": name = words[index + 1]
            default: break
            }
            index += 1
        }
        guard let file, file.hasPrefix("/"), let name, !name.isEmpty, !name.hasPrefix("-") else { return nil }
        self.init(file: file, name: name)
    }

    /// Words as a shell would split them, quotes taken off.
    static func words(_ line: String) -> [String] {
        var words: [String] = []
        var word = ""
        var quote: Character?
        var inWord = false
        for character in line {
            if let open = quote {
                if character == open { quote = nil } else { word.append(character) }
            } else if character == "'" || character == "\"" {
                quote = character
                inWord = true
            } else if character == " " || character == "\t" {
                if inWord { words.append(word) }
                word = ""
                inWord = false
            } else {
                word.append(character)
                inWord = true
            }
        }
        if inWord { words.append(word) }
        return words
    }
}

extension ConnectionFailure {
    /// The buttons for this failure, first the one most likely to help. `address` is where
    /// the host is, when WRLD knows it.
    public func offers(address: String?) -> [ConnectionOffer] {
        if let address, LocalNetwork.suggestsPermission(address: address, failure: self) {
            return [.allowLocalNetwork, .reconnect]
        }
        switch self {
        // Plain ssh would stop at the same host key, or ask the question you just declined.
        // Forgetting the old key is its own, confirmed step; then ssh asks about the new one.
        case .hostKeyChanged(_, _, .some): return [.forgetHostKey, .reconnect]
        case .hostKeyChanged, .hostKeyRejected, .cancelled: return [.reconnect]
        default: return [.reconnect, .plainSSH]
        }
    }
}

/// The last lines a master wrote on stderr, and what they mean.
public struct MasterLog: Equatable, Sendable {
    public static let kept = 20

    /// The last `kept` lines, oldest first.
    public private(set) var lines: [String] = []
    /// macOS Tahoe's ssh warns when the server has no post-quantum key exchange: shown as a
    /// chip on the host, not as noise in a pane.
    public private(set) var warnsPostQuantum = false
    private var partial = ""

    public init() {}

    /// Takes what the master wrote, in whatever pieces it arrived.
    public mutating func append(_ text: String) {
        partial += text
        // ssh ends its lines with \r\n, a single Character to Swift: look for the \n itself.
        while let newline = partial.unicodeScalars.firstIndex(of: "\n") {
            let line = String(partial.unicodeScalars[..<newline]).trimmingWhitespace
            partial = String(partial.unicodeScalars[partial.unicodeScalars.index(after: newline)...])
            add(line)
        }
    }

    /// The master has connected: what it wrote while logging in says nothing about how it
    /// ends later. The post-quantum warning stays.
    public mutating func connected() {
        lines = []
    }

    /// Ends a last line written without a newline.
    public mutating func finish() {
        if !partial.isEmpty { add(partial.trimmingWhitespace) }
        partial = ""
    }

    private mutating func add(_ line: String) {
        guard !line.isEmpty else { return }
        if line.contains("post-quantum") {
            warnsPostQuantum = true
            return
        }
        // The rest of the post-quantum warning.
        if line.hasPrefix("** ") { return }
        // accept-new noting a new host key: news, not a reason anything failed.
        if line.hasPrefix("Warning: Permanently added ") { return }
        lines.append(line)
        if lines.count > Self.kept { lines.removeFirst(lines.count - Self.kept) }
    }

    /// Why the connection failed, the most specific reason in the lines; nil when they say
    /// nothing about it.
    public var failure: ConnectionFailure? {
        // A "channel N: …" line is a forwarding channel failing (a tunnel to a port nothing
        // answers, say), not the master's own connection. Left in, its "Connection refused"
        // would be mistaken for why the master failed, hiding the real reason on a later line.
        let relevant = lines.filter { !Self.isChannelLine($0) }
        let text = relevant.joined(separator: "\n")
        if text.contains("REMOTE HOST IDENTIFICATION HAS CHANGED") {
            return .hostKeyChanged(
                fingerprint: fingerprint(in: relevant), knownHostsLine: offendingLine(in: relevant),
                removal: relevant.lazy.compactMap { KeyRemoval(parsing: $0) }.first)
        }
        if text.contains("Host key verification failed") { return .hostKeyRejected }
        if text.contains("Too many authentication failures") { return .tooManyAuthenticationFailures }
        if let line = relevant.last(where: { $0.contains("Permission denied (") }),
            let open = line.range(of: "Permission denied ("), let close = line[open.upperBound...].firstIndex(of: ")")
        {
            let methods = line[open.upperBound..<close].split(separator: ",").map(String.init)
            return .authenticationFailed(methods: methods)
        }
        if text.contains("Could not resolve hostname") { return .unknownHost }
        if text.contains("No route to host") { return .noRoute }
        if text.contains("Network is unreachable") { return .networkUnreachable }
        if text.contains("Connection refused") { return .refused }
        if text.contains("timed out") { return .timedOut }
        if text.contains("Connection closed by") || text.contains("Connection reset by")
            || text.contains("closed by remote host")
        {
            return .closedByRemote
        }
        return relevant.last.map(ConnectionFailure.other)
    }

    /// `channel 1: open failed: …`: a forwarding channel, not the master's connection.
    static func isChannelLine(_ line: String) -> Bool {
        line.hasPrefix("channel ") && (line.dropFirst("channel ".count).first?.isNumber ?? false)
    }

    /// "The fingerprint for the ED25519 key sent by the remote host is", then the print on
    /// the next line.
    private func fingerprint(in lines: [String]) -> String? {
        for (index, line) in lines.enumerated() where line.hasSuffix("sent by the remote host is") {
            guard index + 1 < lines.count else { break }
            var print = lines[index + 1]
            if print.hasSuffix(".") { print.removeLast() }
            return print
        }
        return nil
    }

    /// "Offending ED25519 key in /Users/r/.ssh/known_hosts:3" gives the file and line.
    private func offendingLine(in lines: [String]) -> String? {
        for line in lines where line.hasPrefix("Offending ") {
            if let range = line.range(of: " key in ") { return String(line[range.upperBound...]) }
        }
        return nil
    }
}
