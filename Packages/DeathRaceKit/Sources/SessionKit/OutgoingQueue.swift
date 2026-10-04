import PTYKit

/// Bytes for the shell, oldest first: typed input and the terminal's replies, in the order
/// they arose.
struct OutgoingQueue {
    private var chunks: [(bytes: [UInt8], isInput: Bool)] = []
    private var offset = 0
    /// Reply bytes waiting. A program that asks faster than it reads the answers loses the
    /// excess instead of growing the queue.
    private(set) var replyBytes = 0
    let replyLimit: Int

    init(replyLimit: Int) {
        self.replyLimit = replyLimit
    }

    var isEmpty: Bool { chunks.isEmpty }

    /// Input is limited before it gets here (`SessionChannel.inputLimit`).
    mutating func appendInput(_ bytes: [UInt8]) {
        if !bytes.isEmpty { chunks.append((bytes, true)) }
    }

    /// Queues one batch of replies whole, or drops it whole if it would take the replies
    /// waiting past the limit: a reply cut short would confuse the program more than a
    /// missing one.
    @discardableResult
    mutating func appendReplies(_ bytes: [UInt8]) -> Bool {
        guard !bytes.isEmpty, replyBytes + bytes.count <= replyLimit else { return false }
        chunks.append((bytes, false))
        replyBytes += bytes.count
        return true
    }

    /// Writes until `write` would block. Returns the input bytes written in full, which no
    /// longer count against the input limit.
    mutating func write(_ write: (UnsafeRawBufferPointer) -> PseudoTerminal.WriteResult) -> Int {
        var writtenInput = 0
        while let (bytes, isInput) = chunks.first {
            let result = bytes.withUnsafeBytes { all in write(UnsafeRawBufferPointer(rebasing: all[offset...])) }
            switch result {
            case .wrote(let n):
                offset += n
                if offset == bytes.count {
                    chunks.removeFirst()
                    offset = 0
                    if isInput { writtenInput += bytes.count } else { replyBytes -= bytes.count }
                }
            case .wouldBlock:
                return writtenInput
            case .closed:
                chunks.removeAll()
                offset = 0
                replyBytes = 0
                return writtenInput
            }
        }
        return writtenInput
    }
}
