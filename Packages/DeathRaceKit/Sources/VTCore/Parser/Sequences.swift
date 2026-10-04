/// Numeric parameters of a CSI or DCS sequence, with colon sub-parameters.
///
/// Stored flat, the way they arrive: `38:2::255:0:128;1` is the values
/// `[38, 2, 0, 255, 0, 128, 1]`, and a bit per value records whether a colon (rather
/// than a semicolon or the end) follows it, which is what marks the next value as a
/// sub-parameter. An empty parameter reads as 0; callers apply the sequence's default.
public struct Params: Sendable, Equatable {
    public static let capacity = 32

    private var storage = InlineArray<32, UInt16>(repeating: 0)
    private var colonMask: UInt32 = 0
    public private(set) var count = 0

    public init() {}

    /// Builds parameters from values, every one followed by a semicolon. For tests.
    public init(_ values: [UInt16]) {
        for value in values.prefix(Self.capacity) { append(value, colonFollows: false) }
    }

    public var isEmpty: Bool { count == 0 }

    public subscript(index: Int) -> UInt16 {
        index < count ? storage[index] : 0
    }

    /// The value at `index`, with 0 or a missing value replaced by `defaultValue`.
    /// Most cursor movements treat 0 and "missing" alike, as 1.
    @inline(__always)
    public func value(at index: Int, default defaultValue: UInt16) -> UInt16 {
        let v = self[index]
        return v == 0 ? defaultValue : v
    }

    /// True when the value at `index` is followed by a colon, so `index + 1` is its sub-parameter.
    @inline(__always)
    public func colonFollows(_ index: Int) -> Bool {
        index < count && index < 32 && (colonMask >> UInt32(index)) & 1 == 1
    }

    /// The index just past the value at `index` and all its colon sub-parameters.
    public func endOfGroup(startingAt index: Int) -> Int {
        var end = index
        while colonFollows(end) { end += 1 }
        return min(end + 1, count)
    }

    mutating func append(_ value: UInt16, colonFollows: Bool) {
        guard count < Self.capacity else { return }
        storage[count] = value
        if colonFollows { colonMask |= 1 << UInt32(count) }
        count += 1
    }

    mutating func removeAll() {
        count = 0
        colonMask = 0
    }

    public static func == (lhs: Params, rhs: Params) -> Bool {
        guard lhs.count == rhs.count, lhs.colonMask == rhs.colonMask else { return false }
        for i in 0..<lhs.count where lhs.storage[i] != rhs.storage[i] { return false }
        return true
    }

    /// The values as an array, for tests and diagnostics.
    public var values: [UInt16] { (0..<count).map { storage[$0] } }
}

/// Intermediate bytes (0x20...0x2F) between a sequence's introducer and its final byte.
/// More than two makes a sequence unrecognizable, so it is ignored.
public struct Intermediates: Sendable, Equatable {
    public private(set) var first: UInt8 = 0
    public private(set) var second: UInt8 = 0
    public private(set) var count: UInt8 = 0
    /// Set when a third intermediate arrived: the sequence will be ignored.
    public private(set) var overflowed = false

    public init() {}

    public init(_ bytes: [UInt8]) {
        for byte in bytes { append(byte) }
    }

    mutating func append(_ byte: UInt8) {
        switch count {
        case 0: first = byte
        case 1: second = byte
        default:
            overflowed = true
            return
        }
        count += 1
    }

    mutating func removeAll() {
        self = Intermediates()
    }

    /// True when the intermediates are exactly `byte` (one byte).
    @inline(__always)
    public func isOnly(_ byte: UInt8) -> Bool { count == 1 && first == byte }
}

/// `ESC [intermediates] final`.
public struct EscapeSequence: Sendable, Equatable {
    public var intermediates: Intermediates
    public var final: UInt8

    public init(intermediates: Intermediates = Intermediates(), final: UInt8) {
        self.intermediates = intermediates
        self.final = final
    }
}

/// `CSI [private marker] [params] [intermediates] final`.
public struct ControlSequence: Sendable, Equatable {
    /// One of `< = > ?`, or 0.
    public var privateMarker: UInt8
    public var params: Params
    public var intermediates: Intermediates
    public var final: UInt8

    public init(
        privateMarker: UInt8 = 0, params: Params = Params(), intermediates: Intermediates = Intermediates(),
        final: UInt8
    ) {
        self.privateMarker = privateMarker
        self.params = params
        self.intermediates = intermediates
        self.final = final
    }
}

/// The header of a DCS string: `DCS [private marker] [params] [intermediates] final`,
/// before its data.
public struct DeviceControlHeader: Sendable, Equatable {
    public var privateMarker: UInt8
    public var params: Params
    public var intermediates: Intermediates
    public var final: UInt8

    public init(
        privateMarker: UInt8 = 0, params: Params = Params(), intermediates: Intermediates = Intermediates(),
        final: UInt8
    ) {
        self.privateMarker = privateMarker
        self.params = params
        self.intermediates = intermediates
        self.final = final
    }
}
