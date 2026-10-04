import Foundation
import PTYKit

/// `~/.ssh/known_hosts` as WRLD's Known hosts page shows it, through `ssh-keygen`, which
/// reads every format the file can hold (hashed names, `[host]:port`, markers). It's the
/// same file plain ssh uses, so trusting or forgetting a key here holds there too.
public enum KnownHosts {
    public static let sshKeygen = "/usr/bin/ssh-keygen"

    /// One key the file trusts.
    public struct Entry: Equatable, Sendable, Identifiable {
        /// The names and addresses it's for; none when they're hashed (`HashKnownHosts`).
        public var hosts: [String]
        /// "ED25519", "RSA", "ECDSA".
        public var type: String
        /// The key's size; nil where ssh-keygen didn't say (looking up one host).
        public var bits: Int?
        /// "SHA256:…", as ssh shows it.
        public var fingerprint: String
        /// Its line in the file, where known.
        public var line: Int?

        public init(hosts: [String], type: String, bits: Int? = nil, fingerprint: String, line: Int? = nil) {
            self.hosts = hosts
            self.type = type
            self.bits = bits
            self.fingerprint = fingerprint
            self.line = line
        }

        public var isHashed: Bool { hosts.isEmpty }
        public var id: String { fingerprint + " " + hosts.joined(separator: ",") }

        /// The page's line: "github.com, 140.82.121.4", or "A hashed name".
        public var title: String { isHashed ? "A hashed name" : hosts.joined(separator: ", ") }
    }

    public enum Failure: Error, Equatable, Sendable {
        /// ssh-keygen couldn't do it, in its words.
        case refused(String)
    }

    /// The lines `ssh-keygen -l -f FILE` prints: `256 SHA256:… github.com,140.82.121.4
    /// (ED25519)`. Anything else is skipped.
    public static func parse(listing: String) -> [Entry] {
        listing.split(whereSeparator: \.isNewline).compactMap { line in
            let fields = line.split(separator: " ", omittingEmptySubsequences: true)
            guard fields.count >= 4, let bits = Int(fields[0]), fields[1].contains(":"),
                let type = fields.last, type.hasPrefix("("), type.hasSuffix(")")
            else { return nil }
            let names = fields[2..<(fields.count - 1)].joined(separator: " ")
            let hosts = names.hasPrefix("|1|") ? [] : names.split(separator: ",").map(String.init)
            return Entry(
                hosts: hosts, type: String(type.dropFirst().dropLast()), bits: bits, fingerprint: String(fields[1]))
        }
    }

    /// What `ssh-keygen -l -F NAME -f FILE` prints: a `# Host NAME found: line 12` line, then
    /// `NAME ED25519 SHA256:…`, for each key it finds.
    public static func parse(found: String) -> [Entry] {
        var entries: [Entry] = []
        var line: Int?
        for text in found.split(whereSeparator: \.isNewline) {
            if text.hasPrefix("#") {
                line = text.split(separator: " ").last.flatMap { Int($0) }
                continue
            }
            let fields = text.split(separator: " ", omittingEmptySubsequences: true)
            guard fields.count == 3, fields[2].contains(":") else { continue }
            entries.append(
                Entry(hosts: [String(fields[0])], type: String(fields[1]), fingerprint: String(fields[2]), line: line))
        }
        return entries
    }

    /// The name ssh files a host's key under: its address, with the port in brackets when
    /// it isn't 22 ("[10.0.4.21]:2222").
    public static func name(host: String, port: Int?) -> String {
        guard let port, port != 22 else { return host }
        return "[\(host)]:\(port)"
    }

    /// Every key in `path`; none when there's no file.
    public static func list(path: String, runner: any ProcessRunner, environment: [String: String]) async -> [Entry] {
        guard FileManager.default.fileExists(atPath: path),
            let result = try? await runner.run(Command([sshKeygen, "-l", "-f", path], environment: environment))
        else { return [] }
        return parse(listing: result.outputText)
    }

    /// The keys in `path` for `name` (as `name(host:port:)` writes it), hashed or not.
    public static func find(
        _ name: String, path: String, runner: any ProcessRunner, environment: [String: String]
    ) async -> [Entry] {
        guard FileManager.default.fileExists(atPath: path),
            let result = try? await runner.run(
                Command([sshKeygen, "-l", "-F", name, "-f", path], environment: environment))
        else { return [] }
        return parse(found: result.outputText)
    }

    /// Forgets every key `path` holds for `name`: the step after a host's key changed and
    /// you've made sure the new one is right. ssh-keygen keeps the old file as `.old`, and
    /// a name it doesn't hold is no failure.
    public static func forget(
        _ name: String, path: String, runner: any ProcessRunner, environment: [String: String]
    ) async throws(Failure) {
        guard !name.isEmpty, !name.hasPrefix("-"), !name.contains(where: \.isNewline) else {
            throw .refused("That isn't a host name.")
        }
        guard path.hasPrefix("/"), !path.contains(where: \.isNewline) else {
            throw .refused("That isn't a known_hosts file.")
        }
        let result = try? await runner.run(Command([sshKeygen, "-R", name, "-f", path], environment: environment))
        guard let result, result.succeeded else {
            throw .refused(SecureEnclaveKeys.lastLine(of: result?.errorText ?? "") ?? "ssh-keygen didn't run.")
        }
    }
}
