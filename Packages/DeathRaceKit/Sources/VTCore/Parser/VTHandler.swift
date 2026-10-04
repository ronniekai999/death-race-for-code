/// Receives what `VTParser` recognizes.
///
/// The parser is generic over its handler, so the compiler specializes it for each one and
/// these calls are direct, not dynamically dispatched. The terminal is one handler; tests
/// use a recording handler.
public protocol VTHandler {
    /// A run of printable ASCII (0x20...0x7E): the hot path, handed over without decoding.
    mutating func printASCII(_ bytes: UnsafeBufferPointer<UInt8>)
    /// One printable character outside ASCII, already decoded; U+FFFD for invalid UTF-8.
    mutating func print(_ scalar: UInt32)
    /// A C0 control (0x00...0x1F except ESC), executed where it appears, even mid-sequence.
    mutating func execute(_ control: UInt8)
    mutating func escapeDispatch(_ sequence: EscapeSequence)
    mutating func controlSequenceDispatch(_ sequence: ControlSequence)
    /// An OSC string, terminated by ST or BEL.
    mutating func operatingSystemCommand(_ payload: UnsafeBufferPointer<UInt8>, terminatedByBEL: Bool)
    /// A DCS string with its data, delivered whole when ST arrives.
    mutating func deviceControlString(_ header: DeviceControlHeader, data: UnsafeBufferPointer<UInt8>)
    /// An APC string (the Kitty graphics protocol travels here).
    mutating func applicationProgramCommand(_ payload: UnsafeBufferPointer<UInt8>)
}
