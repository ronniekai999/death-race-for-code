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
/// continuations. The ChildProcess is touched by one thread per side (writer: input; reader:
/// output and reaping), so no two threads share a field.
///
/// `close()` stops the writer, which closes the child's input; a responsive sftp-server then
/// sees end of file and exits, the reader gets EOF, reaps, and both threads end.
public final class SFTPSession: SFTPTransport, @unchecked Sendable {
    private let child: ChildProcess

    private let lock = NSLock()
    private var inboxFrames: [[UInt8]] = []
    private var inboxWaiter: CheckedContinuation<[UInt8], any Error>?
    private var closed = false
    private var failure: (any Error)?

    private let writeCondition = NSCondition()
    private var writeQueue: [(frame: [UInt8], done: CheckedContinuation<Void, any Error>)] = []
    private var stopWriter = false

    /// A frame body larger than this means the stream desynced or a server went rogue; fail
    /// rather than accumulate it. Real packets are a 32 KiB chunk plus a little, or a directory
    /// listing — all well under this.
    private static let maxFrameBody = 16 << 20

    private init(child: ChildProcess) {
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
        writeCondition.lock()
        stopWriter = true
        writeCondition.signal()
        writeCondition.unlock()
    }

    // MARK: - Reader thread

    private func readerLoop() {
        let fd = child.outputFD
        var buffer = [UInt8](repeating: 0, count: 65_536)
        var accumulator: [UInt8] = []
        var start = 0  // index of the first unconsumed byte in `accumulator`
        while true {
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
                    deliver(Array(accumulator[start..<(start + total)]))
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

    private func deliver(_ frame: [UInt8]) {
        lock.lock()
        if let waiter = inboxWaiter {
            inboxWaiter = nil
            lock.unlock()
            waiter.resume(returning: frame)
        } else {
            inboxFrames.append(frame)
            lock.unlock()
        }
    }

    private func finishReading(with error: any Error) {
        lock.lock()
        if failure == nil { failure = error }
        let waiter = inboxWaiter
        inboxWaiter = nil
        lock.unlock()
        waiter?.resume(throwing: error)
        child.closeOutput()
        _ = child.waitForExit(timeoutMilliseconds: 2_000)
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
                finishReading(with: SFTPError.transportClosed)
                child.closeInput()
                return
            }
        }
    }
}
