import PTYKit
import ScreenProtocol
import VTCore

#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#endif

/// The session thread: everything here runs on it and nowhere else.
final class SessionLoop {
    let pty: PseudoTerminal
    let terminal: Terminal
    let channel: SessionChannel
    private var builder = DeltaBuilder()

    /// Typed input and the terminal's replies, waiting for the shell to read them. Input
    /// counts against the channel's input limit until written.
    private var outgoing = OutgoingQueue(replyLimit: SessionLoop.replyLimit)
    static let replyLimit = 1 << 20

    /// Events from a delta the app gave up on (it asked for a snapshot): they go out with the
    /// next one.
    private var carriedEvents: [TerminalEvent] = []

    private var exitWatch: Int32?
    private var running = true
    private var exitStatus: ExitStatus??

    /// The app asked for something (a snapshot, a scroll, a resize): publish even in the
    /// middle of a synchronized frame.
    private var mustPublish = true
    /// Whether anyone is watching. Off for a session the daemon holds with no client: the
    /// shell keeps running and the engine keeps reading, but no delta is built for nobody.
    private var publishing = true
    private var passwordStateChanged = false
    private var publishedVersion: UInt64 = .max
    private var readingPassword = false
    /// While synchronized output (mode 2026) is on, publishing waits for the program to
    /// finish its frame, until this deadline: a program that never turns it off must not
    /// freeze the screen. Nil when not holding, including after the deadline passed.
    private var syncDeadline: Int?
    private var syncSeen = false
    static let syncWatchdog = 1_000

    private var readBuffer = [UInt8](repeating: 0, count: 64 * 1024)
    /// Read at most this much, or for this long, before looking at commands again, so a flood
    /// cannot starve typing or a resize. Time matters too: a few bytes can ask for a lot of
    /// work (a repeat count, a screen fill).
    static let readBudget = 1 << 20
    static let readTimeBudget = 20
    /// After the shell exits, what it left is read within these budgets; a background job can
    /// keep a Linux terminal open and writing long after.
    static let drainTimeBudget = 100

    init(pty: PseudoTerminal, terminal: Terminal, channel: SessionChannel) {
        self.pty = pty
        self.terminal = terminal
        self.channel = channel
    }

    func run() {
        exitWatch = pty.makeExitWatch()
        setPriority(focused: true)
        while running {
            wait()
            processCommands()
            guard running else { break }
            readAvailable()
            writeOutgoing()
            publishIfNeeded()
        }
        finish()
    }

    // MARK: - Waiting

    private var ptyClosed = false
    private var childExited = false

    private func wait() {
        var fds: [pollfd] = [pollfd(fd: channel.wake.readFD, events: Int16(POLLIN), revents: 0)]
        if !ptyClosed {
            var events = Int16(POLLIN)
            if !outgoing.isEmpty { events |= Int16(POLLOUT) }
            fds.append(pollfd(fd: pty.masterFD, events: events, revents: 0))
        }
        if let exitWatch, !childExited {
            fds.append(pollfd(fd: exitWatch, events: Int16(POLLIN), revents: 0))
        }
        let timeout = syncTimeRemaining().map { Int32($0) } ?? -1
        while poll(&fds, nfds_t(fds.count), timeout) < 0 && errno == EINTR {}
        if fds[0].revents != 0 { channel.wake.drain() }
        if let exitWatch, !childExited, fds.last?.fd == exitWatch, fds.last!.revents != 0 {
            childExited = true
        }
    }

    // MARK: - Commands

    private func processCommands() {
        let commands = channel.mailbox.withLock { box in
            defer { box.commands.removeAll(keepingCapacity: true) }
            return box.commands
        }
        var resize: (columns: Int, rows: Int, cellWidth: Int, cellHeight: Int)?
        for command in commands {
            guard running else {
                // Hung up earlier in this batch: the rest only needs its questions answered.
                if case .query(let query) = command { query.cancel() }
                continue
            }
            switch command {
            case .input(let bytes, let typed):
                outgoing.appendInput(bytes)
                // Typing returns a scrolled-back view to the bottom, at once.
                if typed, builder.viewportOffset > 0 {
                    builder.scrollToBottom()
                    mustPublish = true
                }
            case .resize(let columns, let rows, let cellWidth, let cellHeight):
                resize = (columns, rows, cellWidth, cellHeight)  // only the last one matters
            case .scroll(let lines):
                builder.scroll(by: lines, in: terminal)
                mustPublish = true
            case .scrollToBottom:
                builder.scrollToBottom()
                mustPublish = true
            case .snapshot:
                // Whatever the app took or has yet to take is no use to it now: forget it, so
                // the next delta cannot build on it. Only the events survive.
                builder.reset()
                let unsent = channel.mailbox.withLock { box in
                    defer {
                        box.pending = nil
                        box.taken = nil
                    }
                    return box.pending?.events ?? []
                }
                carriedEvents = TerminalEvent.coalesced(carriedEvents + unsent)
                mustPublish = true
            case .focus(let focused):
                setPriority(focused: focused)
            case .setBasePalette(let palette):
                terminal.setBasePalette(palette)
            case .clear(let kind):
                if terminal.clear(kind) { mustPublish = true }
            case .publishing(let on):
                publishing = on
                // Coming back, whoever is watching now has nothing: the next delta is a full one.
                if on { mustPublish = true }
            case .query(let query):
                answer(query)
            case .close:
                exitStatus = .some(pty.hangUp())
                running = false
            }
        }
        guard running else { return }
        if let resize {
            // The engine first, then the program: its redraw must find the new size.
            terminal.resize(columns: resize.columns, rows: resize.rows)
            try? pty.resize(
                TerminalSize(
                    rows: UInt16(clamping: terminal.rows), columns: UInt16(clamping: terminal.columns),
                    pixelWidth: UInt16(clamping: terminal.columns * resize.cellWidth),
                    pixelHeight: UInt16(clamping: terminal.rows * resize.cellHeight)))
            mustPublish = true
        }
    }

    private func answer(_ query: SessionChannel.Query) {
        switch query {
        case .text(let range, let generation, let reply):
            guard generation == terminal.generation else { return reply.resume(returning: nil) }
            reply.resume(returning: TextExtractor.text(in: range) { terminal.line($0) })
        case .foregroundProcess(let reply):
            reply.resume(returning: pty.foregroundProcess())
        }
    }

    // MARK: - Reading and writing

    private func readAvailable() {
        guard !ptyClosed else { return }
        var budget = Self.readBudget
        let deadline = PseudoTerminal.monotonicMilliseconds() + Self.readTimeBudget
        reading: while budget > 0 {
            let result = readBuffer.withUnsafeMutableBytes { pty.read(into: $0) }
            switch result {
            case .bytes(let n):
                readBuffer.withUnsafeBufferPointer { terminal.feed(UnsafeBufferPointer(rebasing: $0[0..<n])) }
                budget -= n
                if PseudoTerminal.monotonicMilliseconds() >= deadline { break reading }
            case .wouldBlock:
                break reading
            case .closed:
                ptyClosed = true
                break reading
            }
        }
        outgoing.appendReplies(terminal.takeReplies())

        // A change here is published like any other change: it does not cut through a
        // synchronized frame (and a line editor toggling echo at every prompt is no reason to).
        let nowReadingPassword = pty.isReadingPassword
        if nowReadingPassword != readingPassword {
            readingPassword = nowReadingPassword
            passwordStateChanged = true
        }
        if terminal.modes.synchronizedOutput {
            if !syncSeen {
                syncSeen = true
                syncDeadline = PseudoTerminal.monotonicMilliseconds() + Self.syncWatchdog
            }
        } else {
            syncSeen = false
            syncDeadline = nil
        }

        // The shell is gone: either its exit was seen, or every holder of the terminal
        // closed it. Read what is left, then stop.
        if childExited || ptyClosed {
            if childExited && !ptyClosed { drainRemainingOutput() }
            // End of file usually means the shell is exiting; give it a moment to finish
            // before hanging up on whatever still holds the terminal.
            exitStatus = .some(pty.waitForExit(timeoutMilliseconds: 200) ?? pty.hangUp(graceMilliseconds: 500))
            running = false
        }
    }

    private func drainRemainingOutput() {
        var budget = Self.readBudget
        let deadline = PseudoTerminal.monotonicMilliseconds() + Self.drainTimeBudget
        while budget > 0 && PseudoTerminal.monotonicMilliseconds() < deadline {
            let result = readBuffer.withUnsafeMutableBytes { pty.read(into: $0) }
            guard case .bytes(let n) = result else { return }
            readBuffer.withUnsafeBufferPointer { terminal.feed(UnsafeBufferPointer(rebasing: $0[0..<n])) }
            budget -= n
        }
    }

    private func writeOutgoing() {
        let writtenInput = outgoing.write { pty.write($0) }
        if writtenInput > 0 { channel.mailbox.withLock { $0.queuedInput -= writtenInput } }
    }

    // MARK: - Publishing

    /// Milliseconds until the synchronized-output watchdog fires, or nil when not holding.
    private func syncTimeRemaining() -> Int? {
        guard let syncDeadline else { return nil }
        let remaining = syncDeadline - PseudoTerminal.monotonicMilliseconds()
        if remaining <= 0 {
            self.syncDeadline = nil  // expired: publish, and stop waking for it
            return nil
        }
        return remaining
    }

    private func publishIfNeeded() {
        // Nobody is watching. What the program printed is still read and still fed to the
        // engine, so its scrollback is all there when someone takes the session up again.
        guard publishing else { return }
        let changed =
            terminal.currentVersion != publishedVersion || !terminal.events.isEmpty || !carriedEvents.isEmpty
            || passwordStateChanged
        guard changed || mustPublish else { return }
        // Synchronized output holds the frame until the program finishes it, unless the
        // app asked for something or the watchdog ran out.
        if !mustPublish, syncTimeRemaining() != nil { return }
        publish()
    }

    private func publish() {
        let events = TerminalEvent.coalesced(carriedEvents + terminal.takeEvents())
        carriedEvents = []
        var notify = false
        // The delta builds on the last one the app took. The app can take another while this
        // one is being built, without holding the lock; then it is built again on that one.
        while true {
            if let taken = channel.mailbox.withLock({ box in
                defer { box.taken = nil }
                return box.taken
            }) {
                builder.didDeliver(taken)
            }
            var delta = builder.makeDelta(from: terminal, events: events)
            delta.readingPassword = readingPassword
            #if DEBUG
                // Debug builds send every delta through the codec the daemon will use.
                delta = try! DeltaCodec.decode(DeltaCodec.encode(delta))
            #endif
            let stored = channel.mailbox.withLock { box in
                guard box.taken == nil else { return false }
                if let unsent = box.pending {
                    box.pending = delta.merging(unsent: unsent)
                } else {
                    box.pending = delta
                    notify = true
                }
                return true
            }
            if stored { break }
        }
        passwordStateChanged = false
        publishedVersion = terminal.currentVersion
        mustPublish = false
        if notify { channel.onUpdate() }
    }

    // MARK: - The end

    private func finish() {
        // Whatever the shell printed last, and its exit, reach the app.
        if exitStatus == nil { exitStatus = .some(pty.hangUp()) }
        pty.close()
        publish()
        if let exitWatch { close(exitWatch) }
        let unanswered = channel.mailbox.withLock { box in
            box.status = .exited(exitStatus ?? nil)
            defer { box.commands.removeAll() }
            return box.commands
        }
        for case .query(let query) in unanswered { query.cancel() }
        channel.onUpdate()
    }

    private func setPriority(focused: Bool) {
        #if canImport(Darwin)
            pthread_set_qos_class_self_np(focused ? QOS_CLASS_USER_INITIATED : QOS_CLASS_UTILITY, 0)
        #endif
    }
}
