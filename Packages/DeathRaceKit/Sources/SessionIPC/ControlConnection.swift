import CPTY
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

/// The one connection an app keeps for as long as it runs, on a thread of its own.
///
/// It never carries a screen, so nothing here is large or urgent, and the only thing that
/// arrives unasked is a session's end — which a client needs even for a session it has not
/// taken up, so that a relaunched app can say how a shell went.
final class ControlConnection {
    static let requestTimeout = 10_000

    private let socket: Int32
    private let registry: SessionRegistry
    private let wake = Locked<WakePipe?>(nil)
    private let pending = Locked<[ControlReply]>([])
    private let finished = Locked(false)
    private var reader: FrameReader
    private var writer = FrameWriter(largestQueue: 4 * SessionWire.largestControlFrame)
    private var buffer = [UInt8](repeating: 0, count: 16 * 1024)
    private var running = true

    /// `reader` comes from the handshake, and may already hold what arrived with it.
    init(socket: Int32, registry: SessionRegistry, reader: FrameReader) {
        self.reader = reader
        self.socket = socket
        self.registry = registry
    }

    deinit {
        close(socket)
    }

    var isFinished: Bool { finished.withLock { $0 } }

    /// Something the client did not ask for. Safe from the daemon's thread.
    func announce(_ reply: ControlReply) {
        pending.withLock { $0.append(reply) }
        wake.withLock { $0 }?.signal()
    }

    func run() {
        // Finished before anything else, so every way out of this function is one the daemon
        // can see. Without it a connection that could not make its pipe — this process out of
        // descriptors — would never be pruned: its socket would stay open and the daemon would
        // count it as busy for ever, so it could never exit on its own.
        defer {
            finished.withLock { $0 = true }
            wake.withLock { $0 = nil }
        }
        guard let pipe = try? WakePipe() else { return }
        wake.withLock { $0 = pipe }
        UnixSocket.setNonBlocking(socket)
        // Anything announced between being added to the daemon's list and the pipe above
        // existing is sitting in `pending` with nothing to wake us for it. One signal, and
        // the first pass collects it instead of waiting.
        pipe.signal()
        while running {
            let ready = UnixSocket.wait(
                socket, forWriting: !writer.isEmpty, wake: pipe.readFD, timeoutMilliseconds: -1)
            pipe.drain()
            collectAnnouncements()
            drainReader()
            if ready.readable { readFrames() }
            if !writeOut() { break }
        }
    }

    private func collectAnnouncements() {
        let ready = pending.withLock { pending -> [ControlReply] in
            defer { pending = [] }
            return pending
        }
        for reply in ready where !writer.queue(reply.encode(), .control) {
            running = false
        }
    }

    /// Anything the handshake read ahead, which no later byte would bring out of the reader.
    private func drainReader() {
        while running, let payload = reader.next() {
            guard let request = try? ControlRequest.decode(payload) else {
                running = false
                return
            }
            handle(request)
        }
    }

    private func readFrames() {
        let count = buffer.withUnsafeMutableBytes { recv(socket, $0.baseAddress, $0.count, 0) }
        if count < 0 {
            if errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK { return }
            running = false
            return
        }
        guard count > 0 else {
            running = false  // the app has gone; its sessions stay
            return
        }
        for payload in reader.append(Array(buffer[0..<count])) {
            guard let request = try? ControlRequest.decode(payload) else {
                running = false
                return
            }
            handle(request)
            if !running { return }
        }
        if reader.isBroken { running = false }
    }

    private func handle(_ request: ControlRequest) {
        switch request {
        case .list:
            reply(.sessions(registry.descriptions()))
        case .spawn(let number, let launch, let configuration, let metadata):
            switch registry.start(launch, configuration: configuration, metadata: metadata) {
            case .success(let started):
                reply(.ready(request: number, id: started.id, token: started.token))
            case .failure(let reason):
                reply(.failed(request: number, reason: reason, detail: Self.sentence(reason, registry.limits)))
            }
        case .adopt(let number, let id):
            switch registry.issueToken(for: id) {
            case .success(let token):
                reply(.ready(request: number, id: id, token: token))
            case .failure(let reason):
                reply(.failed(request: number, reason: reason, detail: Self.sentence(reason, registry.limits)))
            }
        case .setMetadata(let id, let metadata):
            registry.setMetadata(metadata, for: id)
        case .end(let id):
            registry.end(id)
        case .handOver:
            registry.handOver()
        case .goodbye:
            running = false
        }
    }

    private func reply(_ message: ControlReply) {
        if !writer.queue(message.encode(), .control) { running = false }
    }

    /// Why, in words, for a log or a sentence on screen.
    static func sentence(_ reason: Refusal, _ limits: DaemonLimits) -> String {
        switch reason {
        case .atCapacity: "\(limits.sessions) sessions are already running"
        case .unknownSession: "there is no such session"
        case .alreadyAttached: "something else is watching that session"
        case .shellWouldNotStart: "the shell would not start"
        case .handingOver: "a newer Death Race has taken over; this one is finishing"
        case .malformed: "that request made no sense"
        }
    }

    private func writeOut() -> Bool {
        writer.write { buffer in
            guard let base = buffer.baseAddress, buffer.count > 0 else { return .wouldBlock }
            let written = cpty_write_no_sigpipe(socket, base, buffer.count)
            if written > 0 { return .wrote(written) }
            if written < 0, errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK { return .wouldBlock }
            return .gone
        }
    }
}
