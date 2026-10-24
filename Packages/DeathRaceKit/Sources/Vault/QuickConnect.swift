import Foundation

/// Quick connect: an ssh command typed into Hear Me Calling as it would be in a shell,
/// `ssh ubuntu@10.0.4.21 -p 2222`, or just `ubuntu@10.0.4.21:2222`. What it reads becomes the
/// New Host sheet's fields, so a host it saves is one the sheet would have saved.
public enum QuickConnect {
    public enum Problem: Error, Equatable, Sendable {
        /// An option it doesn't take, as typed: `-L`.
        case option(String)
        /// `-p`, `-l` or `-i` with nothing after it.
        case missingValue(String)
        /// Words after the server: a command to run there.
        case command
        case draft(HostDraft.Problem)

        /// What its row says.
        public var sentence: String {
            switch self {
            case .option(let option):
                "Quick connect takes -p, -l and -i. Run ssh with \(option) in a pane instead."
            case .missingValue("-p"): "-p needs the port after it."
            case .missingValue("-l"): "-l needs the user name after it."
            case .missingValue(let option): "\(option) needs the key file after it."
            case .command: "Quick connect opens a shell, so nothing goes after the server."
            case .draft(.userInAddress): "-l names one user and the address another. Keep one of them."
            case .draft(.portInAddress): "-p gives one port and the address another. Keep one of them."
            case .draft(.keyFile): "That key file’s path can’t be given to ssh."
            case .draft(let problem): problem.sentence
            }
        }
    }

    /// The fields `text` names, or what's wrong with them; nil when `text` isn't quick
    /// connect at all. It is when it starts with the word `ssh` and something follows, or is
    /// one word with a user in it or an `ssh://` in front.
    public static func draft(_ text: String) -> Result<HostDraft, Problem>? {
        let words = text.split(whereSeparator: \.isWhitespace).map(String.init)
        guard let first = words.first else { return nil }
        let arguments: ArraySlice<String>
        if first == "ssh" {
            guard words.count > 1 else { return nil }
            arguments = words.dropFirst()
        } else if words.count == 1, first.contains("@") || first.hasPrefix("ssh://") {
            arguments = words[...]
        } else {
            return nil
        }

        var destination: String?
        var user = ""
        var port = ""
        var keyFile: String?
        var index = arguments.startIndex
        // As ssh reads them: options before or after the server, a value after its option
        // or joined to it (`-p2222`).
        while index < arguments.endIndex {
            let word = arguments[index]
            index += 1
            guard word.hasPrefix("-"), word.count > 1 else {
                guard destination == nil else { return .failure(.command) }
                destination = word
                continue
            }
            let option = String(word.prefix(2))
            guard ["-p", "-l", "-i"].contains(option) else { return .failure(.option(option)) }
            var value = String(word.dropFirst(2))
            if value.isEmpty {
                // The next word, unless it's another option: `-l -p2222` is missing its user. A
                // key file's path may start with `-`.
                guard index < arguments.endIndex, option == "-i" || !arguments[index].hasPrefix("-") else {
                    return .failure(.missingValue(option))
                }
                value = arguments[index]
                index += 1
            }
            switch option {
            case "-p": port = value
            case "-l": user = value
            default: keyFile = value
            }
        }
        guard var address = destination else { return .failure(.draft(.noAddress)) }
        // ssh://user@host:port, which ssh takes too.
        if address.hasPrefix("ssh://") {
            address.removeFirst("ssh://".count)
            if address.hasSuffix("/") { address.removeLast() }
        }
        var draft = HostDraft(address: address, user: user, port: port)
        if let keyFile { draft.signIn = .keyFile((keyFile as NSString).expandingTildeInPath) }
        do throws(HostDraft.Problem) {
            _ = try draft.host()
        } catch {
            return .failure(.draft(error))
        }
        return .success(draft)
    }

    /// How a connection reads in one line: `ubuntu@10.0.4.21:2222`, an IPv6 address in
    /// brackets when a port follows it.
    public static func place(_ connection: Connection) -> String {
        let user = connection.user.map { $0 + "@" } ?? ""
        guard let port = connection.port else { return user + connection.address }
        let address = connection.address.contains(":") ? "[\(connection.address)]" : connection.address
        return "\(user)\(address):\(port)"
    }

    /// The host `draft` names that WRLD or `~/.ssh/config` already has, so quick connect
    /// opens it rather than saving it twice: a WRLD host reached the same way, or, for a bare
    /// name, a WRLD host or an alias called that. A host named after its own address, as
    /// quick connect names one, isn't found by that name: `ssh 10.0.4.21` means port 22 as
    /// you, not the `ubuntu@10.0.4.21:2222` saved under it.
    public static func existing(for draft: HostDraft, in vault: Vault, aliases: [String]) -> HostRef? {
        guard let wanted = try? draft.host().connection else { return nil }
        let reached = vault.hosts.first { host in
            guard let connection = host.connection else { return false }
            return connection.address.lowercased() == wanted.address.lowercased() && connection.user == wanted.user
                && connection.port == wanted.port && connection.identity == wanted.identity
                && connection.jumpHostID == nil
        }
        if let reached { return .vault(reached.id) }
        // `ssh prod-api`: what it's called, not where it is.
        guard wanted.user == nil, wanted.port == nil, wanted.identity == .automatic else { return nil }
        let name = wanted.address
        let named = vault.hosts.first { host in
            host.sshConfigAlias == name || (host.name == name && host.connection?.address != name)
        }
        if let named {
            return .vault(named.id)
        }
        return aliases.contains(name) ? .sshConfig(alias: name) : nil
    }
}
