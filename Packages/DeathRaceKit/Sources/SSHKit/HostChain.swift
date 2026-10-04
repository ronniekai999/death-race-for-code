import Foundation
import PTYKit

/// The hops ssh takes to reach a host, outermost jump host first and the host itself last,
/// each named as ssh's prompts will name it. The askpass broker matches a saved password to
/// the hop asking for it by these names, so a jump server never receives another hop's.
///
/// Worked out the way ssh works it out. For `ProxyJump A,B` ssh runs
/// `ssh [-l user] [-p port] -J A -F <config> -W … B`, and each hop's own config can add
/// jumps of its own; every hop's user and name come from `ssh -G` with the same arguments.
public struct HostChain: Equatable, Sendable {
    public struct Hop: Equatable, Sendable {
        /// What ssh was asked to reach: an alias, or a name from a `ProxyJump` line.
        public var alias: String
        /// `user@host` as its prompts say it: `HostKeyAlias` when set, else the host name.
        public var prompt: AskpassPrompt.Hop
        /// The name ssh files this hop's key under in `known_hosts`, and the files it keeps
        /// them in — from `ssh -G`. "Forget the Old Key" trusts a changed-key warning only
        /// when its host and file match one of these, never the server's own words.
        public var knownHostsName: String?
        public var knownHostsFiles: [String]

        public init(
            alias: String, prompt: AskpassPrompt.Hop, knownHostsName: String? = nil, knownHostsFiles: [String] = []
        ) {
            self.alias = alias
            self.prompt = prompt
            self.knownHostsName = knownHostsName
            self.knownHostsFiles = knownHostsFiles
        }
    }

    /// Each hop's `known_hosts` identity, for `KeyRemoval.isConfirmed(by:)`.
    public var knownHostsHops: [(name: String?, files: [String])] {
        hops.map { ($0.knownHostsName, $0.knownHostsFiles) }
    }

    public enum Failure: Error, Equatable, Sendable {
        /// `ssh -G` refused the host: its config has an error, ssh's words.
        case unreadable(String)
        /// Jump hosts that lead back to themselves, or more than `deepest` of them.
        case tooDeep
    }

    /// Outermost jump host first; the host itself last.
    public var hops: [Hop]

    public init(hops: [Hop]) {
        self.hops = hops
    }

    /// More jump hosts than anyone means to use.
    public static let deepest = 8

    /// Asks `ssh -F config -G` about `alias` and each jump host on the way to it.
    public static func resolve(
        alias: String, config: String, runner: any ProcessRunner, environment: [String: String]
    ) async throws(Failure) -> HostChain {
        var seen: Set<[String]> = []
        return HostChain(
            hops: try await hops(
                to: alias, extra: [], config: config, runner: runner, environment: environment, seen: &seen))
    }

    private static func hops(
        to alias: String, extra: [String], config: String, runner: any ProcessRunner,
        environment: [String: String], seen: inout Set<[String]>
    ) async throws(Failure) -> [Hop] {
        let asked = extra + [alias]
        guard seen.insert(asked).inserted, seen.count <= deepest else { throw .tooDeep }
        let arguments = [SSHCommand.ssh, "-F", config, "-G"] + asked
        let result: ChildResult
        do {
            result = try await runner.run(Command(arguments, environment: environment, timeoutMilliseconds: 10_000))
        } catch {
            throw .unreadable("ssh couldn't be started.")
        }
        guard result.succeeded else {
            let line = result.errorText.split(whereSeparator: \.isNewline).last.map(String.init)
            throw .unreadable(line ?? "ssh -G failed.")
        }
        let effective = EffectiveConfig(parsing: result.outputText)
        let hop = Hop(
            alias: alias,
            prompt: AskpassPrompt.Hop(user: effective.user ?? "", host: effective.promptHost ?? alias),
            knownHostsName: effective.knownHostsName, knownHostsFiles: effective.userKnownHostsFiles)
        guard let proxyJump = effective.proxyJump else { return [hop] }

        let specs = proxyJump.split(separator: ",").map(String.init)
        guard let last = specs.last.map(JumpSpec.init(parsing:)) else { return [hop] }
        var jumpArguments: [String] = []
        if let user = last.user { jumpArguments += ["-l", user] }
        if let port = last.port { jumpArguments += ["-p", String(port)] }
        if specs.count > 1 { jumpArguments += ["-J", specs.dropLast().joined(separator: ",")] }
        let before = try await hops(
            to: last.host, extra: jumpArguments, config: config, runner: runner, environment: environment,
            seen: &seen)
        return before + [hop]
    }

    /// What the broker may answer for this chain. `secret` gives the saved password and the
    /// WRLD name for a hop's alias, when WRLD knows that host. Two hops ssh would name alike
    /// (one user on one machine, reached on two ports) can't be told apart by their prompts,
    /// so neither gets a saved password: both are asked.
    public func askpassContext(
        hostName: String, mayAsk: Bool = true, secret: (String) -> (ref: SecretRef, name: String)?
    ) -> AskpassContext {
        var passwords: [AskpassPrompt.Hop: SecretRef] = [:]
        var names: [SecretRef: String] = [:]
        var ambiguous: Set<AskpassPrompt.Hop> = []
        for hop in hops {
            guard let (ref, name) = secret(hop.alias) else { continue }
            if let existing = passwords[hop.prompt], existing != ref { ambiguous.insert(hop.prompt) }
            passwords[hop.prompt] = ref
            names[ref] = name
        }
        // A prompt also names a hop WRLD doesn't save for, which would make it ambiguous too.
        for hop in hops where secret(hop.alias) == nil && passwords[hop.prompt] != nil {
            ambiguous.insert(hop.prompt)
        }
        for prompt in ambiguous { passwords[prompt] = nil }
        return AskpassContext(hostName: hostName, passwords: passwords, hostNames: names, mayAsk: mayAsk)
    }
}

/// One entry of a `ProxyJump` list: `[user@]host[:port]`, or the same as an `ssh://` URI.
/// IPv6 addresses come in brackets.
struct JumpSpec: Equatable {
    var user: String?
    var host: String
    var port: Int?

    init(user: String? = nil, host: String, port: Int? = nil) {
        self.user = user
        self.host = host
        self.port = port
    }

    init(parsing text: String) {
        var rest = Substring(text)
        if rest.hasPrefix("ssh://") { rest = rest.dropFirst(6) }
        if let at = rest.lastIndex(of: "@") {
            user = String(rest[..<at])
            rest = rest[rest.index(after: at)...]
        }
        if rest.hasPrefix("["), let close = rest.firstIndex(of: "]") {
            host = String(rest[rest.index(after: rest.startIndex)..<close])
            let after = rest[rest.index(after: close)...]
            port = after.hasPrefix(":") ? Int(after.dropFirst()) : nil
        } else if let colon = rest.firstIndex(of: ":"), rest.lastIndex(of: ":") == colon {
            host = String(rest[..<colon])
            port = Int(rest[rest.index(after: colon)...])
        } else {
            host = String(rest)
        }
    }
}
