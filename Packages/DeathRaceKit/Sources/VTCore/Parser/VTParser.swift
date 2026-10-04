/// The DEC/ANSI escape-sequence parser.
///
/// The state machine is Paul Williams' (https://vt100.net/emu/dec_ansi_parser), the model
/// behind xterm, Alacritty's vte and Ghostty, with the changes every modern terminal makes:
///
/// * UTF-8 is decoded in the ground state; 8-bit C1 controls are not recognized, because
///   in UTF-8 those bytes are parts of characters.
/// * Colons separate sub-parameters (`38:2::r:g:b`, `4:3`) instead of voiding the sequence.
/// * OSC strings also end at BEL (xterm), and OSC, DCS and APC strings are capped at
///   `maxStringLength` so a stream with no terminator cannot grow memory without bound.
///
/// Printable ASCII in the ground state is found eight bytes at a time and handed over as one
/// run: that is the path `cat bigfile.log` takes.
public struct VTParser: Sendable {
    public enum State: UInt8, Sendable {
        case ground
        case escape
        case escapeIntermediate
        case csiEntry
        case csiParam
        case csiIntermediate
        case csiIgnore
        case dcsEntry
        case dcsParam
        case dcsIntermediate
        case dcsPassthrough
        case dcsIgnore
        case oscString
        case sosPmApcString
    }

    /// 8 MiB: generous for clipboard writes (OSC 52) and images, finite for garbage.
    public static let maxStringLength = 8 * 1024 * 1024

    public private(set) var state: State = .ground
    private var utf8 = UTF8Decoder()

    private var params = Params()
    private var accumulator: UInt16 = 0
    private var paramStarted = false
    private var sawSeparator = false
    private var pendingColon = false
    private var privateMarker: UInt8 = 0
    private var intermediates = Intermediates()

    private var string: [UInt8] = []
    private var stringOverflowed = false
    private var stringIsAPC = false
    private var dcsHeader = DeviceControlHeader(final: 0)

    public init() {}

    // MARK: - Feeding

    public mutating func feed<H: VTHandler>(_ bytes: UnsafeBufferPointer<UInt8>, into handler: inout H) {
        guard let base = bytes.baseAddress else { return }
        let count = bytes.count
        var index = 0
        while index < count {
            if state == .ground && !utf8.isMidSequence {
                let run = printableASCIIRun(base + index, count - index)
                if run > 0 {
                    handler.printASCII(UnsafeBufferPointer(start: base + index, count: run))
                    index += run
                    if index == count { return }
                }
            }
            let byte = base[index]
            index += 1
            if state == .ground {
                ground(byte, &handler)
            } else {
                advance(byte, &handler)
            }
        }
    }

    /// Convenience for tests and tools.
    public mutating func feed<H: VTHandler>(_ bytes: [UInt8], into handler: inout H) {
        bytes.withUnsafeBufferPointer { feed($0, into: &handler) }
    }

    // MARK: - Ground

    @inline(__always)
    private mutating func ground<H: VTHandler>(_ byte: UInt8, _ handler: inout H) {
        if byte < 0x80 {
            if utf8.reset() { handler.print(UTF8Decoder.replacement) }
            switch byte {
            case 0x1B: enterEscape()
            case 0x7F: break
            case 0x20...0x7E:
                var b = byte
                withUnsafePointer(to: &b) { handler.printASCII(UnsafeBufferPointer(start: $0, count: 1)) }
            default: handler.execute(byte)
            }
            return
        }
        switch utf8.feed(byte) {
        case .pending: break
        case .scalar(let scalar): printScalar(scalar, &handler)
        case .invalid: handler.print(UTF8Decoder.replacement)
        case .invalidThenReprocess:
            handler.print(UTF8Decoder.replacement)
            // The byte that cut the sequence short may itself be invalid (`E0 80`): that is a
            // second maximal subpart and a second U+FFFD.
            switch utf8.feed(byte) {
            case .scalar(let scalar): printScalar(scalar, &handler)
            case .invalid: handler.print(UTF8Decoder.replacement)
            case .pending, .invalidThenReprocess: break
            }
        }
    }

    @inline(__always)
    private func printScalar<H: VTHandler>(_ scalar: UInt32, _ handler: inout H) {
        // C1 controls arriving as UTF-8 (U+0080...U+009F) are not printable; xterm in UTF-8
        // mode and Ghostty drop them.
        if scalar >= 0x80 && scalar <= 0x9F { return }
        handler.print(scalar)
    }

    // MARK: - Everything else

    private mutating func advance<H: VTHandler>(_ byte: UInt8, _ handler: inout H) {
        // Transitions from anywhere.
        switch byte {
        case 0x18, 0x1A:  // CAN, SUB: abandon the sequence
            abandonString()
            handler.execute(byte)
            state = .ground
            return
        case 0x1B:
            finishString(&handler)
            enterEscape()
            return
        default:
            break
        }

        switch state {
        case .ground:
            ground(byte, &handler)

        case .escape:
            switch byte {
            case 0x00...0x1F: handler.execute(byte)
            case 0x20...0x2F:
                intermediates.append(byte)
                state = .escapeIntermediate
            case 0x50: enterDCS()
            case 0x58, 0x5E: enterString(apc: false)  // SOS, PM: consumed and dropped
            case 0x5F: enterString(apc: true)  // APC
            case 0x5B: enterCSI()
            case 0x5D: enterOSC()
            case 0x30...0x7E:
                handler.escapeDispatch(EscapeSequence(intermediates: intermediates, final: byte))
                state = .ground
            default: break  // DEL and 8-bit bytes
            }

        case .escapeIntermediate:
            switch byte {
            case 0x00...0x1F: handler.execute(byte)
            case 0x20...0x2F: intermediates.append(byte)
            case 0x30...0x7E:
                if !intermediates.overflowed {
                    handler.escapeDispatch(EscapeSequence(intermediates: intermediates, final: byte))
                }
                state = .ground
            default: break
            }

        case .csiEntry:
            switch byte {
            case 0x00...0x1F: handler.execute(byte)
            case 0x20...0x2F:
                intermediates.append(byte)
                state = .csiIntermediate
            case 0x30...0x3B:
                param(byte)
                state = .csiParam
            case 0x3C...0x3F:
                privateMarker = byte
                state = .csiParam
            case 0x40...0x7E: dispatchCSI(byte, &handler)
            default: break
            }

        case .csiParam:
            switch byte {
            case 0x00...0x1F: handler.execute(byte)
            case 0x30...0x3B: param(byte)
            case 0x3C...0x3F: state = .csiIgnore
            case 0x20...0x2F:
                intermediates.append(byte)
                state = .csiIntermediate
            case 0x40...0x7E: dispatchCSI(byte, &handler)
            default: break
            }

        case .csiIntermediate:
            switch byte {
            case 0x00...0x1F: handler.execute(byte)
            case 0x20...0x2F: intermediates.append(byte)
            case 0x30...0x3F: state = .csiIgnore
            case 0x40...0x7E: dispatchCSI(byte, &handler)
            default: break
            }

        case .csiIgnore:
            switch byte {
            case 0x00...0x1F: handler.execute(byte)
            case 0x40...0x7E: state = .ground
            default: break
            }

        case .dcsEntry:
            switch byte {
            case 0x20...0x2F:
                intermediates.append(byte)
                state = .dcsIntermediate
            case 0x30...0x3B:
                param(byte)
                state = .dcsParam
            case 0x3C...0x3F:
                privateMarker = byte
                state = .dcsParam
            case 0x40...0x7E: hookDCS(byte)
            default: break  // C0 is ignored inside a DCS header
            }

        case .dcsParam:
            switch byte {
            case 0x30...0x3B: param(byte)
            case 0x3C...0x3F: state = .dcsIgnore
            case 0x20...0x2F:
                intermediates.append(byte)
                state = .dcsIntermediate
            case 0x40...0x7E: hookDCS(byte)
            default: break
            }

        case .dcsIntermediate:
            switch byte {
            case 0x20...0x2F: intermediates.append(byte)
            case 0x30...0x3F: state = .dcsIgnore
            case 0x40...0x7E: hookDCS(byte)
            default: break
            }

        case .dcsPassthrough:
            if byte != 0x7F { appendToString(byte) }

        case .dcsIgnore:
            break

        case .oscString:
            switch byte {
            case 0x07:
                dispatchOSC(terminatedByBEL: true, &handler)
                state = .ground
            case 0x00...0x1F: break
            default: appendToString(byte)
            }

        case .sosPmApcString:
            if byte >= 0x20 { appendToString(byte) }
        }
    }

    // MARK: - Actions

    private mutating func enterEscape() {
        state = .escape
        intermediates.removeAll()
    }

    private mutating func clearSequence() {
        params.removeAll()
        accumulator = 0
        paramStarted = false
        sawSeparator = false
        pendingColon = false
        privateMarker = 0
        intermediates.removeAll()
    }

    private mutating func enterCSI() {
        clearSequence()
        state = .csiEntry
    }

    private mutating func enterDCS() {
        clearSequence()
        state = .dcsEntry
    }

    private mutating func enterOSC() {
        resetString(apc: false)
        state = .oscString
    }

    private mutating func enterString(apc: Bool) {
        resetString(apc: apc)
        state = .sosPmApcString
    }

    @inline(__always)
    private mutating func param(_ byte: UInt8) {
        switch byte {
        case 0x30...0x39:
            let next = UInt32(accumulator) * 10 + UInt32(byte - 0x30)
            accumulator = UInt16(min(next, 0xFFFF))
            paramStarted = true
        case 0x3A:  // ':' ends this value; the next one is its sub-parameter
            params.append(accumulator, colonFollows: true)
            accumulator = 0
            paramStarted = false
            sawSeparator = true
        default:  // ';'
            params.append(accumulator, colonFollows: false)
            accumulator = 0
            paramStarted = false
            sawSeparator = true
        }
    }

    /// Commits the parameter being typed, if the sequence had any parameters at all:
    /// `CSI H` has none, `CSI ;5H` has two (an empty one, then 5).
    private mutating func finishParams() {
        if paramStarted || sawSeparator {
            params.append(accumulator, colonFollows: false)
        }
    }

    private mutating func dispatchCSI<H: VTHandler>(_ final: UInt8, _ handler: inout H) {
        finishParams()
        if !intermediates.overflowed {
            handler.controlSequenceDispatch(
                ControlSequence(
                    privateMarker: privateMarker, params: params, intermediates: intermediates, final: final)
            )
        }
        state = .ground
    }

    private mutating func hookDCS(_ final: UInt8) {
        finishParams()
        dcsHeader = DeviceControlHeader(
            privateMarker: privateMarker, params: params, intermediates: intermediates, final: final)
        resetString(apc: false)
        state = intermediates.overflowed ? .dcsIgnore : .dcsPassthrough
    }

    private mutating func resetString(apc: Bool) {
        string.removeAll(keepingCapacity: string.capacity <= 64 * 1024)
        stringOverflowed = false
        stringIsAPC = apc
    }

    @inline(__always)
    private mutating func appendToString(_ byte: UInt8) {
        guard !stringOverflowed else { return }
        if string.count >= Self.maxStringLength {
            stringOverflowed = true
            return
        }
        string.append(byte)
    }

    private mutating func dispatchOSC<H: VTHandler>(terminatedByBEL: Bool, _ handler: inout H) {
        if !stringOverflowed {
            string.withUnsafeBufferPointer { handler.operatingSystemCommand($0, terminatedByBEL: terminatedByBEL) }
        }
        resetString(apc: false)
    }

    /// ESC ends a string: OSC, DCS and APC are dispatched (ESC \ is the proper terminator),
    /// then the escape sequence starts.
    private mutating func finishString<H: VTHandler>(_ handler: inout H) {
        switch state {
        case .oscString:
            dispatchOSC(terminatedByBEL: false, &handler)
        case .dcsPassthrough:
            if !stringOverflowed {
                string.withUnsafeBufferPointer { handler.deviceControlString(dcsHeader, data: $0) }
            }
            resetString(apc: false)
        case .sosPmApcString:
            if stringIsAPC && !stringOverflowed {
                string.withUnsafeBufferPointer { handler.applicationProgramCommand($0) }
            }
            resetString(apc: false)
        default:
            break
        }
    }

    /// CAN and SUB cancel a string without dispatching it.
    private mutating func abandonString() {
        switch state {
        case .oscString, .dcsPassthrough, .sosPmApcString: resetString(apc: false)
        default: break
        }
    }
}

// MARK: - Printable ASCII scan

/// The length of the run of bytes in 0x20...0x7E starting at `pointer`, checked eight bytes
/// at a time: a word contains a byte below 0x20 or above 0x7E exactly when one of these
/// classic bit tricks leaves a high bit set.
@inline(__always)
func printableASCIIRun(_ pointer: UnsafePointer<UInt8>, _ count: Int) -> Int {
    let raw = UnsafeRawPointer(pointer)
    var offset = 0
    let ones: UInt64 = 0x0101_0101_0101_0101
    let highs: UInt64 = 0x8080_8080_8080_8080
    while offset + 8 <= count {
        let word = raw.loadUnaligned(fromByteOffset: offset, as: UInt64.self)
        let below = (word &- ones &* 0x20) & ~word & highs
        let above = ((word &+ ones &* (0x7F - 0x7E)) | word) & highs
        if below | above != 0 { break }
        offset += 8
    }
    while offset < count {
        let byte = pointer[offset]
        if byte < 0x20 || byte > 0x7E { break }
        offset += 1
    }
    return offset
}
