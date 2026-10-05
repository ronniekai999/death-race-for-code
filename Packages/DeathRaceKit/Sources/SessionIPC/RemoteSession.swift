import CPTY
import Foundation
import IPCKit
import PTYKit
import ScreenProtocol
import SessionKit
import VTCore

#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#endif

/// A session the daemon holds, behind the same interface as one in this process.
///
/// Screens are pulled, as they always were: one waits in a mailbox, the view takes it on its
/// next frame, and taking it sends the acknowledgement that lets the daemon hand over the
/// next. So nothing on the path from a keystroke to the screen waits for a round trip, and a
/// view that stops taking deltas makes the daemon coalesce rather than queue.
public final class RemoteSession: ShellSession, @unchecked Sendable {
    /// What may wait for the program to read it, matching what a session in this process
    /// allows, so a runaway paste is refused at the same place either way.
    public static let inputLimit = 16 * 1024 * 1024

    private enum Waiter {
        case text(CheckedContinuation<String?, Never>)
        case foreground(CheckedContinuation<ForegroundProcess?, Never>)

        /// Answers, with nothing if the reply was not the kind expected — which a connection
        /// that has gone counts as.
        func answer(_ reply: StreamReply?) {
            switch (self, reply) {
            case (.text(let continuation), .text(_, let text)): continuation.resume(returning: text)
            case (.text(let continuation), _): continuation.resume(returning: nil)
            case (.foreground(let continuation), .foreground(_, let process)):
                continuation.resume(returning: process)
            case (.foreground(let continuation), _): continuation.resume(returning: nil)
            }
        }
    }

    private struct State {
        /// Screens waiting to be taken. The acknowledgement keeps this at one; it is a queue
        /// rather than a slot because each screen is built on the one before, so folding two
        /// together would give the mirror a screen whose base it does not hold. In order is
        /// always right; replacing never is.
        var waiting: [ScreenDelta] = []
        var status = Session.Status.running
        var outgoing: [StreamRequest] = []
        var queuedInput = 0
        var waiters: [UInt32: Waiter] = [:]
        var issued: Set<UInt32> = []
        var nextRequest: UInt32 = 1
        /// The connection has gone. Everything after that is refused rather than queued.
        var closed = false
    }

    public let id: SessionID
    /// The daemon holds the shell, so it outlives this process. That is the whole feature.
    public var outlivesItsClient: Bool { true }
    private let socket: Int32
    private let wake: WakePipe
    private let onUpdate: @Sendable () -> Void
    private let state = Locked(State())
    /// How many screens may wait before the daemon is considered to have broken the window.
    private static let mostWaiting = 8

    private let startingReader: FrameReader

    /// Takes over `socket`, which must already have attached. `reader` comes from that
    /// handshake and may already hold the first screen, which arrived with its reply.
    init(
        id: SessionID, socket: Int32, wake: WakePipe, reader: FrameReader,
        onUpdate: @escaping @Sendable () -> Void
    ) {
        startingReader = reader
        self.id = id
        self.socket = socket
        self.wake = wake
        self.onUpdate = onUpdate
        UnixSocket.setNonBlocking(socket)
        let thread = Thread { [self] in carry() }
        thread.name = "Death Race session link"
        thread.stackSize = 1 << 20
        thread.start()
    }

    // MARK: - What a session is told

    @discardableResult
    public func send(_ bytes: [UInt8]) -> Bool { offer(bytes, typed: true) }

    @discardableResult
    public func sendReport(_ bytes: [UInt8]) -> Bool { offer(bytes, typed: false) }

    /// Input goes in pieces, so one paste is many frames and an acknowledgement or a keypress
    /// can go between them rather than after all of it.
    private func offer(_ bytes: [UInt8], typed: Bool) -> Bool {
        guard !bytes.isEmpty else { return true }
        let accepted = state.withLock { state -> Bool in
            guard !state.closed, state.queuedInput + bytes.count <= Self.inputLimit else { return false }
            state.queuedInput += bytes.count
            var offset = 0
            while offset < bytes.count {
                let end = min(offset + SessionWire.largestInputChunk, bytes.count)
                state.outgoing.append(.input(Array(bytes[offset..<end]), typed: typed))
                offset = end
            }
            return true
        }
        if accepted { wake.signal() }
        return accepted
    }

    public func resize(columns: Int, rows: Int, cellPixelWidth: Int, cellPixelHeight: Int) {
        tell(.resize(columns: columns, rows: rows, cellPixelWidth: cellPixelWidth, cellPixelHeight: cellPixelHeight))
    }

    public func scroll(by lines: Int) { tell(.scroll(by: lines)) }
    public func scrollToBottom() { tell(.scrollToBottom) }
    public func requestSnapshot() { tell(.snapshot) }
    public func setFocused(_ focused: Bool) { tell(.focus(focused)) }
    public func setBasePalette(_ palette: Palette) { tell(.setBasePalette(palette)) }
    public func clear(_ kind: Terminal.ClearKind) { tell(.clear(kind)) }

    /// Ends the shell.
    public func close() { tell(.close) }

    /// Leaves the shell running for someone to take up again. This is what quitting means.
    ///
    /// It does not wait. The daemon learns of it when the message arrives, and until then the
    /// session is still one something is watching — so taking it up again straight afterwards
    /// can be refused as already watched, and has to be retried. No path in the app does that:
    /// detaching happens at quit, and taking up at the next launch.
    public func detach() { tell(.detach) }

    private func tell(_ request: StreamRequest) {
        let queued = state.withLock { state -> Bool in
            guard !state.closed else { return false }
            state.outgoing.append(request)
            return true
        }
        if queued { wake.signal() }
    }

    // MARK: - What a session is asked

    public func text(in range: TextRegion, generation: UInt64) async -> String? {
        await withCheckedContinuation { continuation in
            ask(.text(continuation)) { .queryText(request: $0, region: range, generation: generation) }
        }
    }

    public func foregroundProcess() async -> ForegroundProcess? {
        await withCheckedContinuation { continuation in
            ask(.foreground(continuation)) { .queryForeground(request: $0) }
        }
    }

    /// Registers the waiter **before** the question goes, so an answer cannot arrive with
    /// nowhere to go — and answers it at once, with nothing, if there is no connection left.
    /// A continuation nobody resumes cannot be cancelled and waits for ever.
    private func ask(_ waiter: Waiter, _ make: (UInt32) -> StreamRequest) {
        let request = state.withLock { state -> UInt32? in
            guard !state.closed, state.waiters.count < 64 else { return nil }
            let number = state.nextRequest
            state.nextRequest &+= 1
            state.waiters[number] = waiter
            state.issued.insert(number)
            state.outgoing.append(make(number))
            return number
        }
        guard request != nil else {
            waiter.answer(nil)
            return
        }
        wake.signal()
    }

    // MARK: - What comes back

    public func takeDelta() -> ScreenDelta? {
        let delta = state.withLock { state -> ScreenDelta? in
            guard !state.waiting.isEmpty else { return nil }
            return state.waiting.removeFirst()
        }
        // Taking it is the acknowledgement: the daemon may build the next one on this.
        if let delta { tell(.ack(version: delta.version)) }
        return delta
    }

    public var status: Session.Status { state.withLock { $0.status } }

    /// Whether the connection to the daemon is still there. A session whose link has gone is
    /// not a session that has ended: the shell may well still be running.
    public var isLinked: Bool { state.withLock { !$0.closed } }

    // MARK: - The thread that carries it

    private func carry() {
        var reader = startingReader
        var writer = FrameWriter(largestQueue: 4 * SessionWire.largestSessionFrame)
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        var running = true

        // The same care as the daemon's own loops: whatever was queued before this thread
        // reached its first wait must not need a second event to be noticed.
        wake.signal()
        while running {
            let ready = UnixSocket.wait(
                socket, forWriting: !writer.isEmpty, wake: wake.readFD, timeoutMilliseconds: -1)
            wake.drain()

            let queued = state.withLock { state -> [StreamRequest] in
                defer { state.outgoing = [] }
                return state.outgoing
            }
            for request in queued where !writer.queue(request.encode(), request.lane) {
                running = false
            }

            // Whatever the handshake read ahead is already assembled in the reader, and no
            // more bytes may ever come: the daemon is waiting for this screen to be
            // acknowledged before it sends another. Drain it before looking at the socket.
            while running, let payload = reader.next() {
                guard let reply = try? StreamReply.decode(payload), receive(reply) else {
                    running = false
                    break
                }
            }

            if running, ready.readable {
                let count = buffer.withUnsafeMutableBytes { recv(socket, $0.baseAddress, $0.count, 0) }
                if count > 0 {
                    for payload in reader.append(Array(buffer[0..<count])) {
                        guard let reply = try? StreamReply.decode(payload), receive(reply) else {
                            running = false
                            break
                        }
                    }
                    if reader.isBroken { running = false }
                } else if count == 0 {
                    running = false
                } else if !(errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK) {
                    running = false
                }
            }

            if running {
                running = writer.write { bytes in
                    guard let base = bytes.baseAddress, bytes.count > 0 else { return .wouldBlock }
                    let written = cpty_write_no_sigpipe(socket, base, bytes.count)
                    if written > 0 { return .wrote(written) }
                    if written < 0, errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK {
                        return .wouldBlock
                    }
                    return .gone
                }
            }
        }
        unlink()
    }

    /// False when what arrived means the connection is no longer worth keeping.
    private func receive(_ reply: StreamReply) -> Bool {
        switch reply {
        case .delta(let bytes):
            guard let delta = try? DeltaCodec.decode(bytes) else { return false }
            let room = state.withLock { state -> Bool in
                guard state.waiting.count < Self.mostWaiting else { return false }
                state.waiting.append(delta)
                return true
            }
            guard room else { return false }
            onUpdate()
        case .status(let status):
            state.withLock { $0.status = status }
            onUpdate()
        case .text(let request, _), .foreground(let request, _):
            let waiter = state.withLock { state -> Waiter? in
                guard state.issued.remove(request) != nil else { return nil }
                return state.waiters.removeValue(forKey: request)
            }
            waiter?.answer(reply)
        case .attached, .refused:
            return false  // only ever the first thing said
        }
        return true
    }

    /// The link has gone. Every question is answered with nothing in one pass, so nothing is
    /// left waiting on a reply that cannot come. The status is left alone: a shell whose link
    /// died has not necessarily ended, and saying it had would be a lie.
    private func unlink() {
        let waiters = state.withLock { state -> [Waiter] in
            state.closed = true
            state.outgoing = []
            let owed = Array(state.waiters.values)
            state.waiters = [:]
            state.issued = []
            return owed
        }
        for waiter in waiters { waiter.answer(nil) }
        closeDescriptor(socket)
        onUpdate()
    }
}
