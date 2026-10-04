import ScreenProtocol
import VTCore

#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#endif

/// One fuzzing input. Two modes, picked by the first byte:
///
/// * 0: the rest is a delta as bytes; decoding must fail cleanly or succeed, never crash.
/// * anything else: the bytes after a size header drive a terminal. Each step is a resize
///   (0xFF, columns, rows), a scroll (0xFE, signed lines) or a chunk of output (length byte,
///   then that many bytes). After every step the delta goes through the codec into a mirror,
///   which must hold exactly what a fresh snapshot holds.
@_cdecl("LLVMFuzzerTestOneInput")
public func fuzz(_ data: UnsafePointer<UInt8>, _ size: Int) -> CInt {
    let input = UnsafeBufferPointer(start: data, count: size)
    guard let mode = input.first else { return 0 }
    if mode == 0 {
        _ = try? DeltaCodec.decode(Array(input.dropFirst()))
        return 0
    }
    guard size >= 3 else { return 0 }

    let terminal = Terminal(
        Terminal.Configuration(
            columns: Int(input[1] % 40) + 1, rows: Int(input[2] % 12) + 1, scrollbackLimitBytes: 16 * 1024,
            answersChecksumRequests: true))
    var builder = DeltaBuilder()
    var mirror = MirrorGrid()
    var index = 3
    while index < size {
        let step = input[index]
        index += 1
        switch step {
        case 0xFF where index + 1 < size:
            terminal.resize(columns: Int(input[index] % 40) + 1, rows: Int(input[index + 1] % 12) + 1)
            index += 2
        case 0xFE where index < size:
            builder.scroll(by: Int(Int8(bitPattern: input[index])), in: terminal)
            index += 1
        default:
            let count = min(Int(step % 64) + 1, size - index)
            terminal.feed(UnsafeBufferPointer(rebasing: input[index..<(index + count)]))
            index += count
        }
        _ = terminal.takeReplies()
        sync(terminal, &builder, &mirror)
    }
    return 0
}

private func sync(_ terminal: Terminal, _ builder: inout DeltaBuilder, _ mirror: inout MirrorGrid) {
    let delta = builder.makeDelta(from: terminal, events: terminal.takeEvents())
    let decoded: ScreenDelta
    do {
        decoded = try DeltaCodec.decode(DeltaCodec.encode(delta))
    } catch {
        fatalError("a delta did not survive the codec: \(error)")
    }
    precondition(decoded == delta, "the codec changed a delta")
    do {
        try mirror.apply(decoded)
    } catch {
        fatalError("a mirror could not apply the next delta: \(error)")
    }
    builder.didDeliver(decoded)

    var fresh = DeltaBuilder()
    fresh.scroll(by: builder.viewportOffset, in: terminal)
    precondition(
        mirror.lines == fresh.makeDelta(from: terminal, events: []).changedRows,
        "the mirror differs from a fresh snapshot")
}
