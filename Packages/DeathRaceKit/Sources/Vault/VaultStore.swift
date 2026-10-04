import Foundation

/// Where `wrld.json` lives: next to the settings file, in `$XDG_CONFIG_HOME/deathrace/`, or
/// `~/.config/deathrace/` when that variable is unset or not an absolute path.
public enum VaultLocation {
    public static func path(environment: [String: String], home: String) -> String {
        if let base = environment["XDG_CONFIG_HOME"], base.hasPrefix("/") {
            return trimmingTrailingSlashes(base) + "/deathrace/wrld.json"
        }
        return trimmingTrailingSlashes(home) + "/.config/deathrace/wrld.json"
    }

    private static func trimmingTrailingSlashes(_ path: String) -> String {
        var path = Substring(path)
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        return path == "/" ? "" : String(path)
    }
}

/// Reading and writing `wrld.json`.
///
/// Saving never writes over what it can't understand: a file it can't read, one that isn't
/// a vault, or one a newer Death Race wrote. Those are left as they are, and saving says why.
public struct VaultStore: Sendable {
    public enum Failure: Error, Equatable, Sendable {
        case unreadable(path: String)
        case undecodable(path: String, reason: String)
        case newer(path: String, version: Int)
        case unwritable(path: String, errno: Int32)
    }

    public let path: String

    public init(path: String) {
        self.path = path
    }

    /// The vault, or an empty one when there's no file yet. A file from a newer build is read
    /// as far as this build understands it; `save` will refuse to write over it.
    public func load() throws(Failure) -> Vault {
        guard let bytes = try readFile() else { return Vault() }
        return try decode(bytes)
    }

    /// Writes `vault`, after checking the file there is one this build may replace.
    public func save(_ vault: Vault) throws(Failure) {
        if let bytes = try readFile() {
            let existing = try decode(bytes)
            if existing.version > Vault.formatVersion { throw .newer(path: path, version: existing.version) }
        }
        var current = vault
        current.version = Vault.formatVersion
        do {
            try AtomicFile.write(Self.encode(current), to: path)
        } catch {
            switch error {
            case .cannotWrite(let target, let code), .cannotRead(let target, let code):
                throw .unwritable(path: target, errno: code)
            }
        }
    }

    /// The file's text: sorted keys, two-space indents and a final newline, so edits diff
    /// cleanly in a dotfiles repo.
    public static func encode(_ vault: Vault) -> [UInt8] {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        // Every type in a vault encodes; a failure here is a programming error.
        guard let data = try? encoder.encode(vault) else { return Array("{}\n".utf8) }
        return Array(data) + [UInt8(ascii: "\n")]
    }

    private func readFile() throws(Failure) -> [UInt8]? {
        do {
            return try AtomicFile.read(path)
        } catch {
            throw .unreadable(path: path)
        }
    }

    private func decode(_ bytes: [UInt8]) throws(Failure) -> Vault {
        // An empty file is an empty vault, not a broken one.
        if bytes.allSatisfy({ $0 == 0x20 || $0 == 0x0A || $0 == 0x0D || $0 == 0x09 }) { return Vault() }
        do {
            return try JSONDecoder().decode(Vault.self, from: Data(bytes))
        } catch let error as DecodingError {
            throw .undecodable(path: path, reason: Self.describe(error))
        } catch {
            throw .undecodable(path: path, reason: "\(error)")
        }
    }

    /// A sentence about where the file went wrong, for the window to show.
    static func describe(_ error: DecodingError) -> String {
        func place(_ path: [any CodingKey]) -> String {
            path.isEmpty
                ? "the top level"
                : path.map { $0.intValue.map { "[\($0)]" } ?? $0.stringValue }.joined(separator: ".")
        }
        switch error {
        case .typeMismatch(_, let context), .valueNotFound(_, let context):
            return "\(place(context.codingPath)): \(context.debugDescription)"
        case .keyNotFound(let key, let context):
            return "\(place(context.codingPath + [key])) is missing"
        case .dataCorrupted(let context):
            return "\(place(context.codingPath)): \(context.debugDescription)"
        @unknown default:
            return "\(error)"
        }
    }
}
