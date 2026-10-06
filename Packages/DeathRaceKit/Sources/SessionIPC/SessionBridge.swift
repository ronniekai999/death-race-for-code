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

/// One attached session's connection, on a thread of its own.
///
/// It is the only thing that calls `takeDelta` on its session, and it takes one only once the
/// client has acknowledged the last — a window of one, end to end. That is not politeness: a
/// delta is built against the last one the client took, so handing over a chain of them and
/// letting the client fold two together would give its mirror a screen whose base it does not
/// hold, and every frame would end in a refusal and a fresh whole screen. With the window,
/// the session coalesces into its own mailbox instead, exactly as it does in process, and a
/// slow client costs one screen rather than a storm of them.
///
/// Nothing here waits. The socket is non-blocking, writes keep what will not fit, and the
/// session's thread is never held up by a client — a client that stops reading entirely is
/// dropped after `writeStall`, and its session carries on without it.
final class SessionBridge {
    /// Handshake deadline: a connection that does not say what it wants is not one.
    static let attachTimeout = 5_000

    private let socket: Int32
    private let registry: SessionRegistry
    private let wake: WakePipe
    private var reader: FrameReader
    private var writer = FrameWriter(largestQueue: 2 * SessionWire.largestSessionFrame)
    private var buffer = [UInt8](repeating: 0, count: 64 * 1024)

    private var id: SessionID?
    private var session: Session?
    private var awaitingAck = false
    private var endSent = false
    private var running = true
    /// Ends the session rather than leaving it: the client said `close`.
    private var closing = false
    private var lastProgress = UnixSocket.monotonicMilliseconds()
    /// Bytes the session would not take yet, held until it will. While this is here the
    /// socket is not read, so the kernel's buffer fills and the client's own writer blocks:
    /// backpressure with no queue of ours to grow.
    private var heldInput: (bytes: [UInt8], typed: Bool)?
    /// How long to wait before trying the held bytes again. Nothing tells this thread that a
    /// program has read its pseudo-terminal — a read that prints nothing publishes no screen —
    /// so while something is held the loop has to come back and look. It backs off to a
    /// second so a program that has stopped reading for good costs one wakeup a second rather
    /// than forty, and it only ticks while something is actually held.
    private var retryIn = SessionBridge.firstRetry
    private static let firstRetry = 25
    private static let longestRetry = 1_000
    /// Answers from the tasks that run the two questions, which finish on another thread.
    private let answers = Locked<[StreamReply]>([])
    private let outstanding = Locked<Set<UInt32>>([])

    private let writeStall: Int

    /// `reader` comes from the handshake, and may already hold what arrived with it.
    init(socket: Int32, registry: SessionRegistry, wake: WakePipe, reader: FrameReader) {
        writeStall = registry.limits.writeStallMilliseconds
        self.reader = reader
        self.socket = socket
        self.registry = registry
        self.wake = wake
    }

    deinit {
        close(socket)
    }

    func run() {
        guard attach() else { return }
        while running {
            let holding = heldInput != nil
            let ready = UnixSocket.wait(
                socket, forReading: !holding, forWriting: !writer.isEmpty, wake: wake.readFD,
                timeoutMilliseconds: pollTimeout())
            wake.drain()
            // Readable without having asked to be told about it can only be a hang-up, which
            // `poll` reports whatever it was asked: the client has gone, and holding bytes for
            // it is pointless.
            if holding, ready.readable { break }
            collectAnswers()
            retryHeldInput()
            drainReader()
            if ready.readable, heldInput == nil { readFrames() }
            offerDelta()
            noticeTheEnd()
            if !writeOut() { break }
            if stalled() { break }
        }
        finish()
    }

    // MARK: - Getting started

    /// The first frame says which session and shows the token for it.
    private func attach() -> Bool {
        guard
            let payload = UnixSocket.readFrame(
                socket, timeoutMilliseconds: Self.attachTimeout, into: &reader),
            let request = try? StreamRequest.decode(payload),
            case .attach(let wanted, let token, let wantsSnapshot) = request
        else {
            refuse(.malformed)
            return false
        }
        switch registry.claim(wanted, token: token, watcher: wake) {
        case .failure(let reason):
            refuse(reason)
            return false
        case .success(let claimed):
            id = wanted
            session = claimed
            UnixSocket.setNonBlocking(socket)
            // Someone is watching again. A client taking a session up holds nothing, so the
            // screen it gets has to be a whole one.
            claimed.setPublishing(true)
            // A client taking a session up holds nothing of its screen, so what it gets has to
            // be a whole one — and whether that is so is the daemon's to know, not the
            // client's to declare. A session that has published before has a builder whose
            // base is some earlier client's last screen, and a delta chained off that would be
            // refused by this client's mirror on arrival and on every frame after it. Only a
            // session that has never published can be picked up mid-chain, because there is no
            // chain yet.
            if wantsSnapshot || claimed.hasPublished { claimed.requestSnapshot() }
            let sizes = registry.descriptions().first { $0.id == wanted }
            _ = writer.queue(
                StreamReply.attached(columns: sizes?.columns ?? 0, rows: sizes?.rows ?? 0).encode(), .control)
            // The loop waits before it works, and a session may already have a screen waiting:
            // it was published before `claim` put this pipe where its thread could find it, so
            // nothing is left to wake us and the loop would park for ever with a delta in hand.
            // Waking ourselves once makes the first pass do its work rather than wait for it.
            wake.signal()
            return true
        }
    }

    /// Says no on a socket still in blocking mode, where one write is enough.
    private func refuse(_ reason: Refusal) {
        _ = UnixSocket.writeAll(socket, Frames.framed(StreamReply.refused(reason).encode()))
    }

    // MARK: - The loop's parts

    private func pollTimeout() -> Int32 {
        var soonest: Int?
        if !writer.isEmpty {
            soonest = max(writeStall - (UnixSocket.monotonicMilliseconds() - lastProgress), 0)
        }
        if heldInput != nil { soonest = min(soonest ?? retryIn, retryIn) }
        guard let soonest else { return -1 }
        return Int32(clamping: soonest)
    }

    /// Anything the handshake read ahead, which no later byte would bring out of the reader.
    private func drainReader() {
        while running, heldInput == nil, let payload = reader.next() {
            guard let request = try? StreamRequest.decode(payload) else {
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
            // End of file. The client went without saying anything, which a crash looks like,
            // so the session is left running rather than ended: the safe reading of silence.
            running = false
            return
        }
        // One `recv` can carry several frames, and the first of them can be input the session
        // will not take. Handling the rest would overwrite what is being held — the bytes
        // would be lost, or reach the shell out of order if the retry happened to land in
        // between — so what is left goes back to the reader to be handled once the hold
        // clears, in the order it arrived.
        var payloads = reader.append(Array(buffer[0..<count]))
        while !payloads.isEmpty {
            let payload = payloads.removeFirst()
            guard let request = try? StreamRequest.decode(payload) else {
                running = false
                return
            }
            handle(request)
            if !running { return }
            if heldInput != nil { break }
        }
        reader.keep(payloads)
        if reader.isBroken { running = false }
    }

    private func handle(_ request: StreamRequest) {
        guard let session, let id else { return }
        switch request {
        case .attach:
            running = false  // once only
        case .input(let bytes, let typed):
            take(bytes, typed: typed, on: session)
        case .resize(let columns, let rows, let cellPixelWidth, let cellPixelHeight):
            session.resize(
                columns: columns, rows: rows, cellPixelWidth: cellPixelWidth, cellPixelHeight: cellPixelHeight)
            registry.noteSize(id, columns: columns, rows: rows)
        case .scroll(let lines):
            session.scroll(by: lines)
        case .scrollToBottom:
            session.scrollToBottom()
        case .snapshot:
            session.requestSnapshot()
        case .focus(let focused):
            session.setFocused(focused)
        case .setBasePalette(let palette):
            session.setBasePalette(palette)
        case .clear(let kind):
            session.clear(kind)
        case .queryText(let request, let region, let generation):
            ask(request) {
                await session.text(in: region, generation: generation)
            } reply: {
                .text(request: request, $0)
            }
        case .queryForeground(let request):
            ask(request) {
                await session.foregroundProcess()
            } reply: {
                .foreground(request: request, $0)
            }
        case .ack:
            awaitingAck = false
        case .close:
            closing = true
            running = false
        case .detach:
            running = false
        }
    }

    private func take(_ bytes: [UInt8], typed: Bool, on session: Session) {
        let accepted = typed ? session.send(bytes) : session.sendReport(bytes)
        guard !accepted else { return }
        // A session whose shell has ended refuses everything, for ever. Holding those bytes
        // would stop this bridge reading its socket at all, so the client's own close or
        // detach would never arrive: the session would sit in the registry watched by a
        // thread that can never finish, counting against the daemon's limit and keeping it
        // from ever exiting. There is nowhere for the bytes to go, so they go nowhere.
        guard session.status == .running else { return }
        heldInput = (bytes, typed)
        retryIn = Self.firstRetry
    }

    /// Try the held bytes again, and while they will not go, leave the socket unread so the
    /// client is held up rather than this.
    ///
    /// Holding only happens when a session's own mailbox is full — sixteen megabytes pasted
    /// into a program that has stopped reading — or when its shell has ended, and the second
    /// of those is no longer held at all. That is why the retry matters and is not tested
    /// here: reaching the first state needs sixteen megabytes through a socket, a
    /// pseudo-terminal and an engine, and the review's other claim about this state — that it
    /// span a core — was measured and turned out to belong to the ended-shell case, which is
    /// gone. With nothing held for an ended shell there is nothing latched for `poll` to keep
    /// reporting, and putting the old behaviour back moved two seconds of daemon time from
    /// 190 ms to 220 ms, which is noise. The read is still switched off while holding, because
    /// it is what makes the kernel do the holding up, but the load-bearing part is this retry:
    /// nothing else will wake this loop, since a program that reads without printing publishes
    /// no screen.
    private func retryHeldInput() {
        guard let held = heldInput, let session else { return }
        guard session.status == .running else {
            heldInput = nil
            return
        }
        let accepted = held.typed ? session.send(held.bytes) : session.sendReport(held.bytes)
        if accepted {
            heldInput = nil
            retryIn = Self.firstRetry
        } else {
            retryIn = min(retryIn * 2, Self.longestRetry)
        }
    }

    /// Runs a question off this thread and queues its answer. The session answers every
    /// question exactly once, with nil once it has ended, so no answer is ever left owing.
    private func ask<Answer: Sendable>(
        _ request: UInt32, _ work: @escaping @Sendable () async -> Answer,
        reply: @escaping @Sendable (Answer) -> StreamReply
    ) {
        let fresh = outstanding.withLock { outstanding -> Bool in
            guard outstanding.count < 64, !outstanding.contains(request) else { return false }
            outstanding.insert(request)
            return true
        }
        guard fresh else { return }
        let answers = answers
        let outstanding = outstanding
        let wake = wake
        Task.detached {
            let answer = await work()
            outstanding.withLock { _ = $0.remove(request) }
            answers.withLock { $0.append(reply(answer)) }
            wake.signal()
        }
    }

    private func collectAnswers() {
        let ready = answers.withLock { answers -> [StreamReply] in
            defer { answers = [] }
            return answers
        }
        for reply in ready where !writer.queue(reply.encode(), reply.lane) {
            running = false
        }
    }

    /// One screen in flight, and only once the last was acknowledged.
    private func offerDelta() {
        guard let session, !awaitingAck, writer.bulkIsEmpty else { return }
        guard let delta = session.takeDelta() else { return }
        if writer.queue(StreamReply.delta(DeltaCodec.encode(delta)).encode(), .bulk) {
            awaitingAck = true
        } else {
            running = false
        }
    }

    private func noticeTheEnd() {
        guard let session, !endSent, session.status != .running else { return }
        endSent = true
        _ = writer.queue(StreamReply.status(session.status).encode(), .control)
    }

    private func writeOut() -> Bool {
        let before = writer.queuedBytes
        let alive = writer.write { buffer in
            guard let base = buffer.baseAddress, buffer.count > 0 else { return .wouldBlock }
            let written = cpty_write_no_sigpipe(socket, base, buffer.count)
            if written > 0 { return .wrote(written) }
            if written < 0, errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK { return .wouldBlock }
            return .gone
        }
        if writer.queuedBytes != before || writer.isEmpty { lastProgress = UnixSocket.monotonicMilliseconds() }
        return alive
    }

    private func stalled() -> Bool {
        guard !writer.isEmpty else { return false }
        return UnixSocket.monotonicMilliseconds() - lastProgress >= writeStall
    }

    private func finish() {
        guard let id else { return }
        if closing {
            registry.end(id)
        } else {
            registry.release(id, watcher: wake)
        }
    }
}
