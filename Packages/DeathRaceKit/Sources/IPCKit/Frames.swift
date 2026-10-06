/// Length-prefixed frames over a stream socket: a 4-byte big-endian length and that many
/// bytes, which is what the askpass helper and its broker have always spoken. The length is
/// big-endian and payloads are little-endian (`DeltaCodec`'s order); they are separate
/// layers, and leaving the frame header as it is keeps the askpass wire format untouched.
public enum Frames {
    /// The header's size, which every limit here is measured without.
    public static let headerSize = 4

    /// `payload` with its length in front.
    public static func framed(_ payload: [UInt8]) -> [UInt8] {
        let length = UInt32(payload.count)
        var out = [UInt8]()
        out.reserveCapacity(payload.count + headerSize)
        out.append(UInt8(truncatingIfNeeded: length >> 24))
        out.append(UInt8(truncatingIfNeeded: length >> 16))
        out.append(UInt8(truncatingIfNeeded: length >> 8))
        out.append(UInt8(truncatingIfNeeded: length))
        out += payload
        return out
    }
}

/// Takes bytes off a socket and hands back whole payloads.
///
/// A length past `limit` breaks the reader for good rather than buffering: the peer is either
/// broken or hostile, and the connection should be dropped. That is the only way a reader
/// fails, so a caller that checks `isBroken` after every `append` has checked everything.
public struct FrameReader: Sendable {
    private var buffer: [UInt8] = []
    /// Payloads assembled but not handed over, so a reader passed from a handshake to the
    /// loop that follows it brings whatever came early with it.
    private var ready: [[UInt8]] = []
    /// The largest payload this reader will assemble, header not counted.
    public let limit: Int
    public private(set) var isBroken = false

    public init(limit: Int) {
        self.limit = limit
    }

    /// How many bytes are held while a frame is still incomplete, for a caller that wants to
    /// see a peer dribbling bytes.
    public var bufferedBytes: Int { buffer.count }

    /// Keeps `payloads` to be handed out by `next`, for a caller that read ahead and is
    /// passing the reader on rather than consuming what it found.
    public mutating func keep(_ payloads: [[UInt8]]) {
        ready += payloads
    }

    /// The next payload already assembled, or nil.
    public mutating func next() -> [UInt8]? {
        ready.isEmpty ? nil : ready.removeFirst()
    }

    /// The payloads `bytes` completes, in order.
    public mutating func append(_ bytes: [UInt8]) -> [[UInt8]] {
        guard !isBroken else { return [] }
        buffer += bytes
        var payloads: [[UInt8]] = []
        while buffer.count >= Frames.headerSize {
            let length =
                Int(buffer[0]) << 24 | Int(buffer[1]) << 16 | Int(buffer[2]) << 8 | Int(buffer[3])
            guard length <= limit else {
                isBroken = true
                buffer = []
                return payloads
            }
            guard buffer.count >= Frames.headerSize + length else { break }
            payloads.append(Array(buffer[Frames.headerSize..<(Frames.headerSize + length)]))
            buffer.removeFirst(Frames.headerSize + length)
        }
        return payloads
    }
}

/// Frames waiting to go out, in two lanes.
///
/// Control frames go before bulk ones, so a key, a resize or an acknowledgement never waits
/// behind a sixteen-megabyte paste, and a reply to a question never waits behind a screen.
/// A frame that has started cannot be interrupted — bytes of two frames may not interleave —
/// so a lane change happens between frames, which is why a bulk frame is worth keeping
/// smallish.
///
/// Writing is non-blocking: `write` hands over as much as the socket takes and keeps the
/// rest, and the caller asks for POLLOUT while `isEmpty` is false. Nothing here ever waits,
/// which is what keeps a session's thread free of its client.
public struct FrameWriter {
    public enum Lane: Sendable {
        /// Small and urgent: acknowledgements, resizes, questions and their answers.
        case control
        /// Large and patient: typed input, pastes, screens.
        case bulk
    }

    /// What the socket said. A count of 0 means it would block, which is not a failure.
    public enum Sent: Sendable, Equatable {
        case wrote(Int)
        case wouldBlock
        case gone
    }

    private var control: [[UInt8]] = []
    private var bulk: [[UInt8]] = []
    /// The frame being written, and how much of it has gone. Taken out of its lane so a
    /// partly written frame can never be reordered behind a newer control frame.
    private var current: [UInt8]?
    private var offset = 0
    private var bytes = 0

    /// How many bytes may wait before `queue` refuses more.
    public let largestQueue: Int

    public init(largestQueue: Int) {
        self.largestQueue = largestQueue
    }

    public var isEmpty: Bool { current == nil && control.isEmpty && bulk.isEmpty }
    /// Whether anything bulk is waiting, including a bulk frame half written.
    public var bulkIsEmpty: Bool { bulk.isEmpty && !currentIsBulk }
    public var queuedBytes: Int { bytes }

    private var currentIsBulk = false

    /// Queues `payload` with its length in front. False when `largestQueue` is already
    /// reached: the caller must then refuse the work rather than grow without bound.
    public mutating func queue(_ payload: [UInt8], _ lane: Lane) -> Bool {
        let frame = Frames.framed(payload)
        guard bytes + frame.count <= largestQueue else { return false }
        bytes += frame.count
        switch lane {
        case .control: control.append(frame)
        case .bulk: bulk.append(frame)
        }
        return true
    }

    /// Hands as much as `send` will take. False once the other end has gone, after which the
    /// writer should be thrown away with its connection.
    public mutating func write(_ send: (UnsafeRawBufferPointer) -> Sent) -> Bool {
        while true {
            if current == nil {
                if !control.isEmpty {
                    current = control.removeFirst()
                    currentIsBulk = false
                } else if !bulk.isEmpty {
                    current = bulk.removeFirst()
                    currentIsBulk = true
                } else {
                    return true
                }
                offset = 0
            }
            guard let frame = current else { return true }
            let result = frame.withUnsafeBytes { whole -> Sent in
                send(UnsafeRawBufferPointer(rebasing: whole[offset...]))
            }
            switch result {
            case .gone:
                return false
            case .wouldBlock:
                return true
            case .wrote(let written):
                guard written > 0 else { return true }
                offset += written
                bytes -= written
                if offset >= frame.count {
                    current = nil
                    currentIsBulk = false
                    offset = 0
                }
            }
        }
    }
}
