import Foundation
import PTYKit

/// macOS 26's Secure Enclave keys for ssh: an identity `sc_auth` makes in the Secure
/// Enclave, used through /usr/lib/ssh-keychain.dylib, with Touch ID at each login. The
/// private key never leaves this Mac, so it can't be backed up or moved to another one, and
/// servers need OpenSSH 8.2 or later to accept it.
///
/// ssh finds such a key through a small "handle" file that `ssh-keygen -K` downloads. Which
/// handle is the new key is told by its public key: the handles are downloaded before and
/// after the identity is made, and the new key is the one that wasn't there before. That
/// needs nothing from sc_auth's own output, whose wording isn't documented.
public struct SecureEnclaveKeys: Sendable {
    public static let scAuth = "/usr/sbin/sc_auth"
    public static let sshKeygen = "/usr/bin/ssh-keygen"

    public struct Created: Equatable, Sendable {
        /// The handle, for `IdentityFile`.
        public var handle: String
        /// "sk-ecdsa-sha2-nistp256@openssh.com AAAA… Death Race", for authorized_keys.
        public var publicKey: String
    }

    public enum Failure: Error, Equatable, Sendable {
        /// sc_auth didn't make the identity, in its words: no Secure Enclave, Touch ID declined.
        case notCreated(String)
        /// ssh-keygen couldn't read the keys back, in its words.
        case notDownloaded(String)
        /// The new key wasn't among the handles, or more than one new key was.
        case notFound
        /// The handle couldn't be kept in the keys folder.
        case notSaved(String)
    }

    /// A resident key's handle as ssh-keygen wrote it, and its public key line.
    struct Resident: Equatable {
        var handle: String
        var publicKey: String
    }

    let runner: any ProcessRunner
    let environment: [String: String]
    /// Where handles are kept: WRLDPaths.keysFolder.
    let keysFolder: String
    /// A new, empty, private folder for ssh-keygen to write into.
    let scratch: @Sendable () throws -> String

    public init(
        runner: any ProcessRunner, environment: [String: String], keysFolder: String,
        scratch: @escaping @Sendable () throws -> String = SecureEnclaveKeys.makeScratchFolder
    ) {
        self.runner = runner
        self.environment = environment
        self.keysFolder = keysFolder
        self.scratch = scratch
    }

    /// Makes a Secure Enclave identity named `label` and keeps its handle as `fileName` in
    /// the keys folder. macOS asks for Touch ID while it's made.
    public func create(label: String, fileName: String) async throws(Failure) -> Created {
        let folders: (before: String, after: String)
        do {
            folders = (try scratch(), try scratch())
        } catch {
            throw .notDownloaded("No folder to download into.")
        }
        // The other handles are copies: none stays behind.
        defer {
            try? FileManager.default.removeItem(atPath: folders.before)
            try? FileManager.default.removeItem(atPath: folders.after)
        }
        // A first key ever: nothing to download yet, which ssh-keygen may call a failure.
        let before = (try? await residentKeys(into: folders.before)) ?? [:]
        let made = try? await runner.run(
            Command(
                [Self.scAuth, "create-ctk-identity", "-l", label, "-k", "p-256-ne", "-t", "bio"],
                environment: environment, timeoutMilliseconds: 120_000))
        guard let made, made.succeeded else {
            throw .notCreated(Self.lastLine(of: made?.errorText ?? "") ?? "sc_auth didn't run.")
        }
        let after = try await residentKeys(into: folders.after)
        let new = after.filter { before[$0.key] == nil }
        guard new.count == 1, let resident = new.first?.value else { throw .notFound }
        return try save(resident, label: label, fileName: fileName)
    }

    /// Every resident key's handle, downloaded into `folder`, which must be empty (a clash
    /// would make ssh-keygen ask "Overwrite?"), keyed by the public key's base64 part.
    func residentKeys(into folder: String) async throws(Failure) -> [String: Resident] {
        var environment = self.environment
        // Its PIN prompt reads standard input when there's no terminal: an empty line.
        environment["SSH_ASKPASS_REQUIRE"] = "never"
        let result = try? await runner.run(
            Command(
                [Self.sshKeygen, "-w", GeneratedConfig.secureEnclaveProvider, "-K", "-N", ""],
                environment: environment, workingDirectory: folder, input: Array("\n".utf8),
                timeoutMilliseconds: 120_000))
        let files = (try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []
        var keys: [String: Resident] = [:]
        for file in files where file.hasSuffix(".pub") {
            let handle = folder + "/" + String(file.dropLast(4))
            guard FileManager.default.fileExists(atPath: handle),
                let line = try? String(contentsOfFile: folder + "/" + file, encoding: .utf8)
            else { continue }
            let publicKey = line.trimmingCharacters(in: .whitespacesAndNewlines)
            let fields = publicKey.split(separator: " ")
            guard fields.count >= 2 else { continue }
            keys[String(fields[1])] = Resident(handle: handle, publicKey: publicKey)
        }
        guard let result, result.succeeded || !keys.isEmpty else {
            throw .notDownloaded(Self.lastLine(of: result?.errorText ?? "") ?? "ssh-keygen didn't run.")
        }
        return keys
    }

    /// Moves the handle and its public key into the keys folder, the public key's comment
    /// replaced by `label`.
    private func save(_ resident: Resident, label: String, fileName: String) throws(Failure) -> Created {
        let manager = FileManager.default
        let handle = keysFolder + "/" + fileName
        let fields = resident.publicKey.split(separator: " ").prefix(2)
        let publicKey = (fields + [Substring(AuthorizedKeys.safeComment(label))]).joined(separator: " ")
        do {
            try manager.createDirectory(
                atPath: keysFolder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            if manager.fileExists(atPath: handle) { try manager.removeItem(atPath: handle) }
            try manager.moveItem(atPath: resident.handle, toPath: handle)
            try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: handle)
            try (publicKey + "\n").write(toFile: handle + ".pub", atomically: true, encoding: .utf8)
        } catch {
            throw .notSaved(error.localizedDescription)
        }
        return Created(handle: handle, publicKey: publicKey)
    }

    public static func makeScratchFolder() throws -> String {
        let folder = NSTemporaryDirectory() + "deathrace-keys-" + UUID().uuidString
        try FileManager.default.createDirectory(
            atPath: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return folder
    }

    static func lastLine(of text: String) -> String? {
        text.split(whereSeparator: \.isNewline).last.map { String($0).trimmingCharacters(in: .whitespaces) }
    }
}

/// A public key into a host's ~/.ssh/authorized_keys, through its master: no new login.
public enum AuthorizedKeys {
    public enum Failure: Error, Equatable, Sendable {
        /// Not a public key line WRLD will hand to a shell.
        case notAKey
        /// The host said no, in its words.
        case refused(String)
    }

    /// Letters, digits and `@._:-` (and spaces), so the comment means the same to every shell.
    static func safeComment(_ text: String) -> String {
        var kept = String.UnicodeScalarView()
        kept.append(contentsOf: text.unicodeScalars.filter { isPlain($0) || " @._:-".unicodeScalars.contains($0) })
        return String(kept).split(separator: " ").joined(separator: " ")
    }

    /// An ASCII letter or digit.
    static func isPlain(_ scalar: Unicode.Scalar) -> Bool {
        ("a"..."z").contains(scalar) || ("A"..."Z").contains(scalar) || ("0"..."9").contains(scalar)
    }

    static func consists(of text: Substring, plainOr extra: String) -> Bool {
        !text.isEmpty && text.unicodeScalars.allSatisfy { isPlain($0) || extra.unicodeScalars.contains($0) }
    }

    /// The command that adds `publicKey` unless its key is there already, under any login
    /// shell: `sh -c '…'` reads the same in sh, bash, zsh and fish, as long as the script
    /// holds no quote or backslash, which a checked key line can't.
    public static func installCommand(for publicKey: String) throws(Failure) -> String {
        let fields = publicKey.split(separator: " ", omittingEmptySubsequences: true)
        guard fields.count >= 2, consists(of: fields[0], plainOr: "@._-"), consists(of: fields[1], plainOr: "+/="),
            fields[1].count >= 16
        else { throw .notAKey }
        let comment = safeComment(fields.dropFirst(2).joined(separator: " "))
        let line = ([String(fields[0]), String(fields[1])] + (comment.isEmpty ? [] : [comment])).joined(separator: " ")
        let file = "~/.ssh/authorized_keys"
        let script =
            "umask 077; mkdir -p ~/.ssh && touch \(file) && "
            + "{ grep -qF \"\(fields[1])\" \(file) || echo \"\(line)\" >> \(file); }"
        return "sh -c '\(script)'"
    }

    /// Adds `publicKey` to the host `alias` names, through its master.
    public static func install(
        _ publicKey: String, alias: String, config: String, runner: any ProcessRunner, environment: [String: String]
    ) async throws(Failure) {
        let command = try installCommand(for: publicKey)
        let result = try? await runner.run(
            Command(SSHCommand.remote(alias: alias, config: config, command: command), environment: environment))
        guard let result, result.succeeded else {
            throw .refused(SecureEnclaveKeys.lastLine(of: result?.errorText ?? "") ?? "ssh didn't run.")
        }
    }
}
