import Foundation
import PTYKit
import SSHKit

#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#endif

/// The real `SFTPTransport`: `ssh … -s sftp` on a host's existing master, its stdin/stdout
/// carrying the binary SFTP stream. The pipe I/O is blocking, so it runs on two dedicated
/// threads — one reading frames, one writing them — bridged to `send`/`receive` with
/// continuations. The ChildProcess is touched by one thread per side — the writer owns the
/// child's input, the reader owns its output, its stderr and the reap — with the pid and the
/// signal behind `childLock`. Neither side ever closes the other's descriptors: the reader
/// spends the session blocked on raw fd numbers, and a descriptor closed under it could be
/// reused immediately by anything else in the process.
///
/// `close()` ends the ssh outright — it signals the child's process group — rather than
/// closing its input and trusting end of file to travel. `ssh -s` keeps its channel open
/// until the *server* closes it, so a close that only shut stdin could leave the ssh in
/// `poll` and the reader thread in `read` for good; a CI run that measured this hung for 21
/// minutes with the subsystem still connected. The signal is what makes the reader's `read`
/// return, so both threads always end and the child is always reaped.
public final class SFTPSession: SFTPTransport, @unchecked Sendable {
    private let child: ChildProcess

    private let lock = NSLock()
    private var inboxFrames: [[UInt8]] = []
    private var inboxBytes = 0
    private var inboxWaiter: CheckedContinuation<[UInt8], any Error>?
    private var closed = false
    private var failure: (any Error)?

    private let writeCondition = NSCondition()
    private var writeQueue: [(frame: [UInt8], done: CheckedContinuation<Void, any Error>)] = []
    private var stopWriter = false

    /// The child's pid is only ever signalled or waited on under this, so a signal can never
    /// land after the reap (when the process group may be somebody else's).
    private let childLock = NSLock()
    private var childSignalled = false
    private var childReaped = false
    /// The tail of what ssh said on stderr, for the sentence when a connection fails. The
    /// reader drains that pipe as well as the frames, so ssh can never block filling it.
    private let errorLock = NSLock()
    private var errorTail: [UInt8] = []

    /// A frame body larger than this means the stream desynced or a server went rogue; fail
    /// rather than accumulate it. Real packets are a 32 KiB chunk plus a little, or a directory
    /// listing — all well under this.
    private static let maxFrameBody = 16 << 20
    /// How much of ssh's stderr to keep. Its complaints are one line ("Connection refused").
    private static let maxErrorTail = 4 << 10
    /// How much may wait unread for the client. A server only ever answers what we asked, so
    /// a queue this deep means it is talking on its own — and reading a frame off a pipe is
    /// far quicker than decoding one, so an unbounded queue is the fastest way to exhaust
    /// memory from the far end.
    private static let maxQueuedFrames = 256
    private static let maxQueuedBytes = 64 << 20

    /// Takes over a child whose stdin and stdout carry the SFTP stream. `connect` is how the
    /// app makes one; the tests use this directly with a child they can make misbehave.
    init(child: ChildProcess) {
        self.child = child
        Thread.detachNewThread { [self] in readerLoop() }
        Thread.detachNewThread { [self] in writerLoop() }
    }

    /// Open the sftp subsystem on `alias`, riding its master through the generated `config`.
    /// `environment` is the master's login environment (PATH, SSH_AUTH_SOCK, the askpass vars).
    public static func connect(alias: String, config: String, environment: [String: String]) throws -> SFTPSession {
        let child = try ChildProcess.spawn(
            executable: SSHCommand.ssh, arguments: SSHCommand.sftp(alias: alias, config: config),
            environment: environment)
        return SFTPSession(child: child)
    }

    /// The ssh's own pid, so the sshd-gated test can prove that closing really ends it.
    var childProcessID: pid_t { child.pid }

    /// Whether `close` has been called, so the reader can tell an ordinary close from a
    /// server that won't stop talking.
    private var isClosed: Bool {
        lock.lock()
        defer { lock.unlock() }
        return closed
    }

    /// What ssh last said on stderr, for the sentence when a session won't start. A hostile
    /// host's pre-auth banner reaches this, and it ends up in a log line, so every control
    /// character goes — otherwise it could forge lines of its own there.
    public var sshErrorText: String {
        errorLock.lock()
        let text = String(decoding: errorTail, as: UTF8.self)
        errorLock.unlock()
        let clean = String(
            String.UnicodeScalarView(
                text.unicodeScalars.map { $0.properties.generalCategory == .control ? " " : $0 }))
        return clean.trimmingCharacters(in: .whitespaces)
    }

    // MARK: - SFTPTransport

    public func send(_ frame: [UInt8]) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            writeCondition.lock()
            if stopWriter {
                writeCondition.unlock()
                continuation.resume(throwing: SFTPError.transportClosed)
                return
            }
            writeQueue.append((frame, continuation))
            writeCondition.signal()
            writeCondition.unlock()
        }
    }

    public func receive() async throws -> [UInt8] {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[UInt8], any Error>) in
            lock.lock()
            if !inboxFrames.isEmpty {
                let frame = inboxFrames.removeFirst()
                inboxBytes -= frame.count
                lock.unlock()
                continuation.resume(returning: frame)
            } else if let failure {
                lock.unlock()
                continuation.resume(throwing: failure)
            } else if closed {
                lock.unlock()
                continuation.resume(throwing: SFTPError.transportClosed)
            } else {
                inboxWaiter = continuation
                lock.unlock()
            }
        }
    }

    public func close() async {
        closeNow()
    }

    /// The locking lives here, off the async path: `NSLock`/`NSCondition` may not be held in an
    /// async function (a lock must never span a suspension).
    private func closeNow() {
        lock.lock()
        let already = closed
        closed = true
        let waiter = inboxWaiter
        inboxWaiter = nil
        lock.unlock()
        waiter?.resume(throwing: SFTPError.transportClosed)
        guard !already else { return }
        stopWriting()
        // The signal, not the end of file, is what ends this: see the note on the class.
        endChild()
    }

    /// Shuts the write queue and fails everything in it, from any thread. **It must not need
    /// the writer thread**, which may already have gone — a failed write ends it. A queue left
    /// open with nobody serving it is the worst kind of broken: `send` would see `stopWriter`
    /// still false, park a continuation on a condition no thread waits on, and never be
    /// resumed. An unresumable continuation can't be cancelled either, so a structured scope
    /// around a transfer would hang for good — the same thing that once took a CI run to its
    /// 25-minute limit, reached by another road.
    private func stopWriting() {
        writeCondition.lock()
        stopWriter = true
        let pending = writeQueue
        writeQueue = []
        writeCondition.broadcast()
        writeCondition.unlock()
        for item in pending { item.done.resume(throwing: SFTPError.transportClosed) }
    }

    // MARK: - The child's ending

    /// Ask the ssh and everything it started to end. Idempotent, safe from any thread, and
    /// never after the reap. It takes the lock only if it is free: when the reader already
    /// holds it the child is being collected anyway, and `close`, which runs on a cooperative
    /// thread, must not wait for that.
    private func endChild() {
        guard childLock.try() else { return }
        defer { childLock.unlock() }
        guard !childReaped, !childSignalled else { return }
        childSignalled = true
        child.signal(SIGTERM)
    }

    /// Collect the child once its output has ended, so it leaves no zombie. Only the reader
    /// thread, which has just seen end of file, calls this.
    private func reapChild() {
        childLock.lock()
        defer { childLock.unlock() }
        guard !childReaped else { return }
        childReaped = true
        if child.waitForExit(timeoutMilliseconds: 2_000) == nil {
            child.signal(SIGKILL)
            _ = child.waitForExit(timeoutMilliseconds: 1_000)
        }
    }

    // MARK: - Reader thread

    private func readerLoop() {
        let fd = child.outputFD
        let errorFD = child.errorFD
        var buffer = [UInt8](repeating: 0, count: 65_536)
        var accumulator: [UInt8] = []
        var start = 0  // index of the first unconsumed byte in `accumulator`
        // Dropped once ssh's stderr ends, so a closed pipe can't be polled in a tight loop.
        var watchErrors = true
        while true {
            // Both pipes, so ssh can never block filling a stderr nobody reads. It waits
            // here with no timeout: an idle session costs nothing until a frame arrives.
            var fds = [pollfd(fd: fd, events: Int16(POLLIN), revents: 0)]
            if watchErrors { fds.append(pollfd(fd: errorFD, events: Int16(POLLIN), revents: 0)) }
            let ready = fds.withUnsafeMutableBufferPointer { poll($0.baseAddress, nfds_t($0.count), -1) }
            if ready < 0 {
                if errno == EINTR { continue }
                finishReading(with: SFTPError.transportClosed)
                return
            }
            if watchErrors, fds.count > 1, fds[1].revents != 0 {
                watchErrors = drainErrors(errorFD, into: &buffer)
            }
            guard fds[0].revents != 0 else { continue }
            let count = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
            if count > 0 {
                accumulator.append(contentsOf: buffer[0..<count])
                while accumulator.count - start >= 4 {
                    let length =
                        (UInt32(accumulator[start]) << 24) | (UInt32(accumulator[start + 1]) << 16)
                        | (UInt32(accumulator[start + 2]) << 8) | UInt32(accumulator[start + 3])
                    if length > Self.maxFrameBody {
                        finishReading(with: SFTPError.invalid("frame too large"))
                        return
                    }
                    let total = 4 + Int(length)
                    if accumulator.count - start < total { break }
                    guard deliver(Array(accumulator[start..<(start + total)])) else {
                        // A frame arriving after an ordinary close isn't the server's fault,
                        // so don't record it as one; a full queue is.
                        finishReading(
                            with: isClosed
                                ? SFTPError.transportClosed
                                : SFTPError.invalid("the server sent more than was asked for"))
                        return
                    }
                    start += total
                }
                if start > 0 {
                    accumulator.removeFirst(start)
                    start = 0
                }
            } else if count == 0 {
                finishReading(with: SFTPError.transportClosed)
                return
            } else if errno == EINTR {
                continue
            } else {
                finishReading(with: SFTPError.transportClosed)
                return
            }
        }
    }

    /// Delivers a frame, or false when the client has fallen so far behind that the queue is
    /// past its cap — which a well-behaved server can't cause, since it only ever replies to
    /// what we asked for. The reader then fails the session instead of growing the queue.
    private func deliver(_ frame: [UInt8]) -> Bool {
        lock.lock()
        if closed {
            lock.unlock()
            return false
        }
        if let waiter = inboxWaiter {
            inboxWaiter = nil
            lock.unlock()
            waiter.resume(returning: frame)
            return true
        }
        guard inboxFrames.count < Self.maxQueuedFrames, inboxBytes + frame.count <= Self.maxQueuedBytes else {
            lock.unlock()
            return false
        }
        inboxFrames.append(frame)
        inboxBytes += frame.count
        lock.unlock()
        return true
    }

    /// Keep the last of what ssh said, without ever blocking: the pipe is non-blocking for
    /// this read, so a stderr with nothing in it costs one `EAGAIN`. False once the pipe has
    /// ended, so the caller stops watching it.
    @discardableResult
    private func drainErrors(_ fd: Int32, into buffer: inout [UInt8]) -> Bool {
        let flags = fcntl(fd, F_GETFL, 0)
        if flags >= 0 { _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK) }
        while true {
            let count = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
            if count == 0 { return false }
            if count < 0 { return errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK }
            errorLock.lock()
            errorTail.append(contentsOf: buffer[0..<count])
            if errorTail.count > Self.maxErrorTail {
                errorTail.removeFirst(errorTail.count - Self.maxErrorTail)
            }
            errorLock.unlock()
        }
    }

    /// Records that the stream has ended and hands the error to whoever is waiting. Safe from
    /// either thread: it touches no descriptor.
    private func failInbox(with error: any Error) {
        lock.lock()
        if failure == nil { failure = error }
        let waiter = inboxWaiter
        inboxWaiter = nil
        inboxFrames = []
        inboxBytes = 0
        lock.unlock()
        waiter?.resume(throwing: error)
    }

    /// The reader thread's own ending, and **only** the reader thread's: it is blocked in
    /// `poll`/`read` on the output and error descriptors for the life of the session, so
    /// nobody else may close them. Closing a descriptor another thread is waiting on is
    /// unspecified, and the number can be reused at once by any other `open` in the process —
    /// a vault write, another session's pipe, the askpass socket. The writer, when its own
    /// side fails, ends the child instead and lets this run.
    private func finishReading(with error: any Error) {
        failInbox(with: error)
        endChild()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        drainErrors(child.errorFD, into: &buffer)
        child.closeOutput()
        reapChild()
    }

    // MARK: - Writer thread

    private func writerLoop() {
        while true {
            writeCondition.lock()
            while writeQueue.isEmpty && !stopWriter { writeCondition.wait() }
            if stopWriter {
                let pending = writeQueue
                writeQueue = []
                writeCondition.unlock()
                for item in pending { item.done.resume(throwing: SFTPError.transportClosed) }
                child.closeInput()
                return
            }
            let item = writeQueue.removeFirst()
            writeCondition.unlock()
            if child.writeInput(item.frame) {
                item.done.resume()
            } else {
                item.done.resume(throwing: SFTPError.transportClosed)
                // Shut the queue before leaving: after this there is no writer thread, so
                // anything still in it — or sent later — would wait for ever.
                stopWriting()
                failInbox(with: SFTPError.transportClosed)
                // Input is this thread's; output and the reap are the reader's. Ending the
                // child is what makes its `read` return so it can do them.
                child.closeInput()
                endChild()
                return
            }
        }
    }
}
