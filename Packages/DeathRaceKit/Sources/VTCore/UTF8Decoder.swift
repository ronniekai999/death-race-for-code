/// Streaming UTF-8 decoding for terminal output.
///
/// Output arrives in arbitrary chunks, so a multi-byte character can straddle two `read`
/// calls; the decoder keeps the partial sequence between calls. Invalid input becomes one
/// U+FFFD per *maximal subpart*, the substitution the Unicode Standard recommends (§3.9,
/// "U+FFFD Substitution of Maximal Subparts"), which is also what xterm, Ghostty and the
/// WHATWG decoder do. Overlong forms, surrogates and values past U+10FFFF are rejected by
/// narrowing the range allowed for the second byte (Table 3-7), never by decoding first.
public struct UTF8Decoder: Sendable, Equatable {
    public static let replacement: UInt32 = 0xFFFD

    public enum Step: Equatable, Sendable {
        /// The byte was consumed and a character is still in progress.
        case pending
        /// A complete scalar.
        case scalar(UInt32)
        /// The sequence in progress was invalid: emit U+FFFD.
        case invalid
        /// The sequence in progress was cut short by this byte: emit U+FFFD, then feed the
        /// same byte again, because it starts something new.
        case invalidThenReprocess
    }

    private var needed: UInt8 = 0
    private var codepoint: UInt32 = 0
    private var lower: UInt8 = 0x80
    private var upper: UInt8 = 0xBF

    public init() {}

    /// True while a multi-byte character is half-received.
    public var isMidSequence: Bool { needed != 0 }

    @inline(__always)
    public mutating func feed(_ byte: UInt8) -> Step {
        if needed == 0 {
            switch byte {
            case 0x00...0x7F:
                return .scalar(UInt32(byte))
            case 0xC2...0xDF:
                begin(remaining: 1, bits: byte & 0x1F)
            case 0xE0:
                begin(remaining: 2, bits: byte & 0x0F, lower: 0xA0)
            case 0xE1...0xEC, 0xEE...0xEF:
                begin(remaining: 2, bits: byte & 0x0F)
            case 0xED:
                begin(remaining: 2, bits: byte & 0x0F, upper: 0x9F)
            case 0xF0:
                begin(remaining: 3, bits: byte & 0x07, lower: 0x90)
            case 0xF1...0xF3:
                begin(remaining: 3, bits: byte & 0x07)
            case 0xF4:
                begin(remaining: 3, bits: byte & 0x07, upper: 0x8F)
            default:
                // 0x80...0xC1 and 0xF5...0xFF never start a character.
                return .invalid
            }
            return .pending
        }

        guard byte >= lower && byte <= upper else {
            reset()
            return .invalidThenReprocess
        }
        codepoint = (codepoint << 6) | UInt32(byte & 0x3F)
        needed -= 1
        lower = 0x80
        upper = 0xBF
        if needed == 0 {
            let scalar = codepoint
            codepoint = 0
            return .scalar(scalar)
        }
        return .pending
    }

    /// Abandons a half-received character, for example when a control byte interrupts it.
    /// Returns true when one was in progress, so the caller can emit U+FFFD for it.
    @discardableResult
    public mutating func reset() -> Bool {
        let wasMid = needed != 0
        needed = 0
        codepoint = 0
        lower = 0x80
        upper = 0xBF
        return wasMid
    }

    @inline(__always)
    private mutating func begin(remaining: UInt8, bits: UInt8, lower: UInt8 = 0x80, upper: UInt8 = 0xBF) {
        needed = remaining
        codepoint = UInt32(bits)
        self.lower = lower
        self.upper = upper
    }
}

extension UTF8Decoder {
    /// Decodes a whole buffer; convenient for tests and tools, not the hot path.
    public mutating func decode<S: Sequence>(_ bytes: S) -> [UInt32] where S.Element == UInt8 {
        var out: [UInt32] = []
        for byte in bytes {
            var step = feed(byte)
            if step == .invalidThenReprocess {
                out.append(Self.replacement)
                step = feed(byte)
            }
            switch step {
            case .scalar(let s): out.append(s)
            case .invalid: out.append(Self.replacement)
            case .pending, .invalidThenReprocess: break
            }
        }
        return out
    }
}
