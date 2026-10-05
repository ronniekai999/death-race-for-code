import PTYKit
import Testing

@testable import SFTPKit

#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#endif

/// The transport against a real child that misbehaves, which is the only way to reach the
/// paths a server or a dying ssh drives. No sshd needed: a shell stands in for it.
@Suite("The SFTP transport", .timeLimit(.minutes(1)))
struct SFTPSessionTests {
    /// A child that closes its stdin at once and then lingers, so every write gets `EPIPE`
    /// while the process is still there.
    private func deafChild() throws -> ChildProcess {
        try ChildProcess.spawn(
            executable: "/bin/sh", arguments: ["sh", "-c", "exec 0<&-; sleep 30"],
            environment: ["PATH": "/bin:/usr/bin"])
    }

    /// A write that fails has to shut the whole queue, not just end the writer thread. If it
    /// only returns, `send`'s `stopWriter` check stays open and every later send parks a
    /// continuation on a condition nobody waits on — never resumed, and not cancellable
    /// either, so a structured scope around a transfer would hang for good.
    @Test func aFailedWriteFailsEverySendAfterIt() async throws {
        let session = SFTPSession(child: try deafChild())
        let frame = [UInt8](repeating: 0, count: 64)
        // Writes buffer until the shell gets to its `exec 0<&-`, so wait for the first real
        // failure rather than assuming which send sees it.
        var failed = false
        for _ in 0..<200 where !failed {
            do {
                try await session.send(frame)
                try await Task.sleep(for: .milliseconds(10))
            } catch {
                failed = true
            }
        }
        try #require(failed, "the child never stopped reading, so there was nothing to test")

        // These are the sends that used to park for ever. Watched from outside, so a
        // regression fails the test instead of hanging the run.
        let cameBack = await Finished.within(10) {
            for _ in 0..<3 {
                await #expect(throws: SFTPError.transportClosed) { try await session.send(frame) }
            }
        }
        #expect(cameBack, "a send after a failed write never came back")
        await session.close()
    }

    /// And a close has to fail what is queued by itself, without the writer thread's help,
    /// for the same reason: by then it may be gone.
    @Test func closingFailsWhatWasQueued() async throws {
        let session = SFTPSession(child: try deafChild())
        for _ in 0..<4 {
            _ = try? await session.send([UInt8](repeating: 0, count: 64))
        }
        await session.close()
        await #expect(throws: SFTPError.transportClosed) { try await session.send([1, 2, 3]) }
        await #expect(throws: (any Error).self) { _ = try await session.receive() }
    }

    /// Closing ends the ssh rather than trusting end of file to travel, so the reader thread
    /// always comes back and the child is always collected.
    @Test func closingEndsTheChild() async throws {
        let child = try ChildProcess.spawn(
            executable: "/bin/sh", arguments: ["sh", "-c", "sleep 30"],
            environment: ["PATH": "/bin:/usr/bin"])
        let pid = child.pid
        let session = SFTPSession(child: child)
        #expect(kill(pid, 0) == 0)
        await session.close()
        var gone = false
        for _ in 0..<100 where !gone {
            if kill(pid, 0) != 0 && errno == ESRCH {
                gone = true
            } else {
                try await Task.sleep(for: .milliseconds(50))
            }
        }
        #expect(gone, "the child outlived the close")
    }
}
