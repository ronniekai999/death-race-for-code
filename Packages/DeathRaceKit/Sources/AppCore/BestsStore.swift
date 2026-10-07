import Foundation
import Vault

/// Reading and writing `bests.json`, so "3.1s faster than your best" means your best and not
/// your best since launch.
///
/// Built on `VaultStore`'s rules, because the question is the same one: never write over what
/// this build cannot understand. A file it cannot read, one that is not a bests file, or one a
/// newer Death Race wrote is left exactly as it is, and saving says why.
///
/// What is in the file, plainly, because it is a file of your command lines: for each command
/// remembered, the text and the fastest successful run in milliseconds. No arguments are
/// stripped and no output is kept. It is written 0600 in a 0700 folder by `AtomicFile`, capped
/// at `CommandBests.limit` commands, never holds a command typed with a leading space, and the
/// `bests-on-disk` setting turns the whole thing off. Deleting the file loses nothing but the
/// records. Your shell already keeps every command line you type, in `~/.zsh_history` at the
/// same mode, so this is a second and much smaller copy rather than a new exposure.
public struct BestsStore: Sendable {
    public enum Failure: Error, Equatable, Sendable {
        case unreadable(path: String)
        case undecodable(path: String, reason: String)
        case newer(path: String, version: Int)
        case unwritable(path: String, errno: Int32)
    }

    /// The format this build reads and writes.
    public static let formatVersion = 1

    /// What the file holds. An array rather than a dictionary on purpose: the order is the one
    /// the cap drops in, so a file read back knows which command to forget next, and a diff in
    /// a dotfiles repo reads as a list rather than as a reshuffle.
    struct Contents: Codable {
        struct Entry: Codable {
            var command: String
            var milliseconds: UInt32
        }
        var version: Int
        var commands: [Entry]
    }

    public let path: String

    public init(path: String) {
        self.path = path
    }

    /// The bests, or empty ones when there is no file yet.
    public func load(limit: Int = 500) throws(Failure) -> CommandBests {
        guard let bytes = try readFile() else { return CommandBests(limit: limit) }
        let contents = try decode(bytes)
        return CommandBests(
            limit: limit, entries: contents.commands.map { ($0.command, $0.milliseconds) })
    }

    /// Writes `bests`, after checking the file there is one this build may replace.
    public func save(_ bests: CommandBests) throws(Failure) {
        if let bytes = try readFile() {
            let existing = try decode(bytes)
            if existing.version > Self.formatVersion { throw .newer(path: path, version: existing.version) }
        }
        let contents = Contents(
            version: Self.formatVersion,
            commands: bests.entries.map { Contents.Entry(command: $0.command, milliseconds: $0.milliseconds) })
        do {
            try AtomicFile.write(Self.encode(contents), to: path)
        } catch {
            switch error {
            case .cannotWrite(let target, let code), .cannotRead(let target, let code):
                throw .unwritable(path: target, errno: code)
            }
        }
    }

    /// Sorted keys, two-space indents and a final newline, as the vault is written, so the file
    /// is readable and diffs cleanly.
    static func encode(_ contents: Contents) -> [UInt8] {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(contents) else { return Array("{}\n".utf8) }
        return Array(data) + [UInt8(ascii: "\n")]
    }

    private func readFile() throws(Failure) -> [UInt8]? {
        do {
            return try AtomicFile.read(path)
        } catch {
            throw .unreadable(path: path)
        }
    }

    private func decode(_ bytes: [UInt8]) throws(Failure) -> Contents {
        do {
            return try JSONDecoder().decode(Contents.self, from: Data(bytes))
        } catch {
            throw .undecodable(path: path, reason: "\(error)")
        }
    }
}
