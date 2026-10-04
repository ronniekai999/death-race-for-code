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

    /// Bytes for the shell, oldest first: typed input and the terminal's replies, in the
    /// order they arose. Input chunks count against the channel's input limit until written.
    private var outgoing: [(bytes: [UInt8], isInput: Bool)] = []
    private var outgoingOffset = 0

    private var exitWatch: Int32?
    private var running = true
    private var exitStatus: ExitStatus??

    /// Something the app has not seen yet beyond row changes: a snapshot request, a scroll.
    private var mustPublish = true
    private var publishedVersion: UInt64 = .max
    private var echoOff = false
    /// While synchronized output (mode 2026) is on, publishing waits for the program to
    /// finish its frame, until this deadline: a program that never turns it off must not
    /// freeze the screen. Nil when not holding, including after the deadline passed.
    private var syncDeadline: Int?
    private var syncSeen = false
    static let syncWatchdog = 1_000

    private var readBuffer = [UInt8](repeating: 0, count: 64 * 1024)
    /// Read at most this much before looking at commands again, so a flood cannot starve
    /// typing or a resize.
    static let readBudget = 1 << 20

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
            switch command {
            case .input(let bytes):
                outgoing.append((bytes, true))
                builder.scrollToBottom()
                mustPublish = true
            case .resize(let columns, let rows, let cellWidth, let cellHeight):
                resize = (columns, rows, cellWidth, cellHeight)  // only the last one matters
            case .scroll(let lines):
                builder.scroll(by: lines, in: terminal)
                mustPublish = true
            case .scrollToBottom:
                builder.scrollToBottom()
                mustPublish = true
            case .snapshot:
                builder.reset()
                mustPublish = true
            case .focus(let focused):
                setPriority(focused: focused)
            case .close:
                exitStatus = .some(pty.hangUp())
                running = false
                return
            }
        }
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

    // MARK: - Reading and writing

    private func readAvailable() {
        guard !ptyClosed else { return }
        var budget = Self.readBudget
        reading: while budget > 0 {
            let result = readBuffer.withUnsafeMutableBytes { pty.read(into: $0) }
            switch result {
            case .bytes(let n):
                readBuffer.withUnsafeBufferPointer { terminal.feed(UnsafeBufferPointer(rebasing: $0[0..<n])) }
                budget -= n
            case .wouldBlock:
                break reading
            case .closed:
                ptyClosed = true
                break reading
            }
        }
        let replies = terminal.takeReplies()
        if !replies.isEmpty { outgoing.append((replies, false)) }

        let nowEchoOff = pty.isEchoDisabled
        if nowEchoOff != echoOff {
            echoOff = nowEchoOff
            mustPublish = true
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
        while true {
            let result = readBuffer.withUnsafeMutableBytes { pty.read(into: $0) }
            guard case .bytes(let n) = result else { return }
            readBuffer.withUnsafeBufferPointer { terminal.feed(UnsafeBufferPointer(rebasing: $0[0..<n])) }
        }
    }

    private func writeOutgoing() {
        var writtenInput = 0
        writing: while let (bytes, isInput) = outgoing.first {
            let result = bytes.withUnsafeBytes { all in
                pty.write(UnsafeRawBufferPointer(rebasing: all[outgoingOffset...]))
            }
            switch result {
            case .wrote(let n):
                outgoingOffset += n
                if outgoingOffset == bytes.count {
                    outgoing.removeFirst()
                    outgoingOffset = 0
                    if isInput { writtenInput += bytes.count }
                }
            case .wouldBlock:
                break writing
            case .closed:
                outgoing.removeAll()
                outgoingOffset = 0
                break writing
            }
        }
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
        let changed = terminal.currentVersion != publishedVersion || !terminal.events.isEmpty
        guard changed || mustPublish else { return }
        // Synchronized output holds the frame until the program finishes it, unless the
        // app asked for something or the watchdog ran out.
        if !mustPublish, syncTimeRemaining() != nil { return }
        publish()
    }

    private func publish() {
        if let taken = channel.mailbox.withLock({ box in
            defer { box.taken = nil }
            return box.taken
        }) {
            builder.didDeliver(taken)
        }
        var delta = builder.makeDelta(from: terminal, events: terminal.takeEvents())
        delta.echoOff = echoOff
        #if DEBUG
            // Debug builds send every delta through the codec the daemon will use.
            delta = try! DeltaCodec.decode(DeltaCodec.encode(delta))
        #endif
        let notify = channel.mailbox.withLock { box in
            if let unsent = box.pending {
                box.pending = delta.merging(unsent: unsent)
                return false
            }
            box.pending = delta
            return true
        }
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
        channel.mailbox.withLock { box in
            box.status = .exited(exitStatus ?? nil)
            box.commands.removeAll()
        }
        channel.onUpdate()
    }

    private func setPriority(focused: Bool) {
        #if canImport(Darwin)
            pthread_set_qos_class_self_np(focused ? QOS_CLASS_USER_INITIATED : QOS_CLASS_UTILITY, 0)
        #endif
    }
}
