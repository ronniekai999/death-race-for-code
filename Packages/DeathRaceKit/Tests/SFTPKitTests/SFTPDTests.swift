import Foundation
import Testing

@testable import SFTPKit

/// The endpoint `scripts/ci-sshd.sh` sets up, read from the environment. The SFTP suite is
/// skipped unless the sshd and its throwaway key are present (`DEATHRACE_SSHD_KEY`), the same
/// gating as `SSHKitTests`' sshd suites.
enum SFTPD {
    static let environment = ProcessInfo.processInfo.environment
    static let key = environment["DEATHRACE_SSHD_KEY"]
    static let target = environment["DEATHRACE_SSHD_TARGET"]
    static let user = environment["DEATHRACE_SSHD_TARGET_USER"] ?? "wrldtarget"

    static var isAvailable: Bool { key != nil && hostPort != nil }

    static var hostPort: (host: String, port: String)? {
        guard let target, let colon = target.lastIndex(of: ":") else { return nil }
        return (String(target[..<colon]), String(target[target.index(after: colon)...]))
    }
}

@Suite("SFTP over a real sshd", .serialized, .enabled(if: SFTPD.isAvailable), .timeLimit(.minutes(1)))
struct SFTPDTests {
    /// A key-only ssh_config pointing an alias at the throwaway sshd — no master, no askpass.
    private func configFile() throws -> String {
        let (host, port) = try #require(SFTPD.hostPort)
        let key = try #require(SFTPD.key)
        let text = """
            Host sftp-target
                HostName \(host)
                Port \(port)
                User \(SFTPD.user)
                IdentityFile \(key)
                IdentitiesOnly yes
                PubkeyAuthentication yes
                PasswordAuthentication no
                KbdInteractiveAuthentication no
                StrictHostKeyChecking no
                UserKnownHostsFile /dev/null
                BatchMode yes
                LogLevel ERROR
            """
        let path = NSTemporaryDirectory() + "sftp-config-" + UUID().uuidString
        try text.write(toFile: path, atomically: true, encoding: .utf8)
        return path
    }

    @Test func aFullRoundTripOverTheRealSubsystem() async throws {
        let config = try configFile()
        let session = try SFTPSession.connect(
            alias: "sftp-target", config: config,
            environment: ["HOME": NSHomeDirectory(), "PATH": "/usr/bin:/bin:/usr/local/bin"])
        let client = SFTPClient(transport: session)
        do {
            try await client.start()
            #expect(await client.serverVersion == 3)

            // Everything under a fresh directory in the user's home, cleaned up at the end.
            let home = try await client.realPath(".")
            let directory = Listing.join(home, "maze-test-" + UUID().uuidString)
            try await client.mkdir(directory)

            // Upload a file larger than one chunk, list it, download it, compare.
            let bytes = (0..<70_000).map { UInt8(($0 * 7) % 251) }
            let remote = Listing.join(directory, "big.bin")
            try await client.upload(remote, bytes: bytes)
            #expect(try await client.stat(remote).size == 70_000)

            let rows = Listing.remote(try await client.list(directory))
            #expect(rows.contains { $0.name == "big.bin" && !$0.isDirectory })

            #expect(try await client.download(remote) == bytes)

            // Rename, remove, rmdir.
            let renamed = Listing.join(directory, "renamed.bin")
            try await client.rename(from: remote, to: renamed)
            #expect(try await client.stat(renamed).size == 70_000)
            try await client.remove(renamed)
            try await client.rmdir(directory)
            await #expect(throws: SFTPError.self) { try await client.stat(directory) }

            try? FileManager.default.removeItem(atPath: config)
        } catch {
            await client.shutDown()
            try? FileManager.default.removeItem(atPath: config)
            throw error
        }
        await client.shutDown()
    }

    /// Closing has to end the ssh, not just shut its stdin. `ssh -s` keeps its channel open
    /// until the server closes it, so a close that trusted end of file to travel left the ssh
    /// in `poll` and the reader thread in `read` for good — and `swift test`, which cannot
    /// exit with a thread blocked on a live child, hung until Linux CI's 25-minute timeout.
    @Test func closingEndsTheSshItStarted() async throws {
        let config = try configFile()
        let session = try SFTPSession.connect(
            alias: "sftp-target", config: config,
            environment: ["HOME": NSHomeDirectory(), "PATH": "/usr/bin:/bin:/usr/local/bin"])
        let pid = session.childProcessID
        let client = SFTPClient(transport: session)
        try await client.start()
        _ = try await client.realPath(".")
        #expect(kill(pid, 0) == 0, "the ssh should be running before the close")
        await client.shutDown()
        try? FileManager.default.removeItem(atPath: config)

        // Gone and reaped: `kill(pid, 0)` still succeeds for a zombie, so ESRCH means the
        // reader thread saw the end, collected the child, and finished.
        var gone = false
        for _ in 0..<100 where !gone {
            if kill(pid, 0) != 0 && errno == ESRCH {
                gone = true
            } else {
                try await Task.sleep(for: .milliseconds(50))
            }
        }
        #expect(gone, "the ssh outlived the close: \(session.sshErrorText)")
    }
}
