import Testing

@testable import VTCore

/// Records everything the parser reports, merging adjacent printable text.
struct RecordingHandler: VTHandler {
    enum Event: Equatable {
        case text(String)
        case execute(UInt8)
        case esc(intermediates: [UInt8], final: Character)
        case csi(marker: Character?, params: [UInt16], colons: [Int], intermediates: [UInt8], final: Character)
        case osc(String, bel: Bool)
        case dcs(marker: Character?, params: [UInt16], intermediates: [UInt8], final: Character, data: String)
        case apc(String)
    }

    var events: [Event] = []

    private mutating func appendText(_ s: String) {
        if case .text(let existing)? = events.last {
            events[events.count - 1] = .text(existing + s)
        } else {
            events.append(.text(s))
        }
    }

    mutating func printASCII(_ bytes: UnsafeBufferPointer<UInt8>) {
        appendText(String(decoding: bytes, as: UTF8.self))
    }

    mutating func print(_ scalar: UInt32) {
        appendText(String(Character(Unicode.Scalar(scalar)!)))
    }

    mutating func execute(_ control: UInt8) { events.append(.execute(control)) }

    mutating func escapeDispatch(_ s: EscapeSequence) {
        events.append(.esc(intermediates: bytes(s.intermediates), final: Character(Unicode.Scalar(s.final))))
    }

    mutating func controlSequenceDispatch(_ s: ControlSequence) {
        let colons = (0..<s.params.count).filter { s.params.colonFollows($0) }
        events.append(
            .csi(
                marker: s.privateMarker == 0 ? nil : Character(Unicode.Scalar(s.privateMarker)),
                params: s.params.values, colons: colons, intermediates: bytes(s.intermediates),
                final: Character(Unicode.Scalar(s.final))))
    }

    mutating func operatingSystemCommand(_ payload: UnsafeBufferPointer<UInt8>, terminatedByBEL: Bool) {
        events.append(.osc(String(decoding: payload, as: UTF8.self), bel: terminatedByBEL))
    }

    mutating func deviceControlString(_ h: DeviceControlHeader, data: UnsafeBufferPointer<UInt8>) {
        events.append(
            .dcs(
                marker: h.privateMarker == 0 ? nil : Character(Unicode.Scalar(h.privateMarker)),
                params: h.params.values, intermediates: bytes(h.intermediates),
                final: Character(Unicode.Scalar(h.final)), data: String(decoding: data, as: UTF8.self)))
    }

    mutating func applicationProgramCommand(_ payload: UnsafeBufferPointer<UInt8>) {
        events.append(.apc(String(decoding: payload, as: UTF8.self)))
    }

    private func bytes(_ i: Intermediates) -> [UInt8] {
        [i.first, i.second].prefix(Int(i.count)).map { $0 }
    }
}

func parse(_ input: String) -> [RecordingHandler.Event] {
    parse(Array(input.utf8))
}

func parse(_ chunks: [UInt8]...) -> [RecordingHandler.Event] {
    var parser = VTParser()
    var handler = RecordingHandler()
    for chunk in chunks { parser.feed(chunk, into: &handler) }
    return handler.events
}

@Suite("VTParser")
struct VTParserTests {
    @Test("printable text arrives as text")
    func plainText() {
        #expect(parse("Legends never die ❯ 999") == [.text("Legends never die ❯ 999")])
    }

    @Test("C0 controls execute in the ground state")
    func controls() {
        #expect(parse("a\r\nb\u{07}") == [.text("a"), .execute(0x0D), .execute(0x0A), .text("b"), .execute(0x07)])
    }

    @Test("a CSI with parameters")
    func csiParams() {
        #expect(
            parse("\u{1B}[12;40H") == [.csi(marker: nil, params: [12, 40], colons: [], intermediates: [], final: "H")])
    }

    @Test("a CSI without parameters has none, and an empty one counts")
    func csiEmptyParams() {
        #expect(parse("\u{1B}[H") == [.csi(marker: nil, params: [], colons: [], intermediates: [], final: "H")])
        #expect(parse("\u{1B}[;5H") == [.csi(marker: nil, params: [0, 5], colons: [], intermediates: [], final: "H")])
    }

    @Test("private markers and intermediates")
    func markersAndIntermediates() {
        #expect(
            parse("\u{1B}[?1049h") == [.csi(marker: "?", params: [1049], colons: [], intermediates: [], final: "h")])
        #expect(parse("\u{1B}[5 q") == [.csi(marker: nil, params: [5], colons: [], intermediates: [0x20], final: "q")])
        #expect(
            parse("\u{1B}[>4;2m") == [.csi(marker: ">", params: [4, 2], colons: [], intermediates: [], final: "m")])
    }

    @Test("colons mark sub-parameters")
    func subParameters() {
        #expect(
            parse("\u{1B}[38:2::255:0:128m")
                == [
                    .csi(
                        marker: nil, params: [38, 2, 0, 255, 0, 128], colons: [0, 1, 2, 3, 4], intermediates: [],
                        final: "m")
                ])
        #expect(
            parse("\u{1B}[4:3;1m") == [
                .csi(marker: nil, params: [4, 3, 1], colons: [0], intermediates: [], final: "m")
            ])
    }

    @Test("sub-parameter groups end where the colons stop")
    func groups() {
        var p = Params()
        p.append(38, colonFollows: true)
        p.append(5, colonFollows: true)
        p.append(196, colonFollows: false)
        p.append(1, colonFollows: false)
        #expect(p.endOfGroup(startingAt: 0) == 3)
        #expect(p.endOfGroup(startingAt: 3) == 4)
    }

    @Test("a control inside a CSI executes without ending it")
    func controlInsideCSI() {
        #expect(
            parse("\u{1B}[1\n;2H") == [
                .execute(0x0A), .csi(marker: nil, params: [1, 2], colons: [], intermediates: [], final: "H"),
            ])
    }

    @Test("CAN and SUB cancel a sequence")
    func cancel() {
        #expect(parse("\u{1B}[12\u{18}A") == [.execute(0x18), .text("A")])
        #expect(parse("\u{1B}]0;title\u{1A}x") == [.execute(0x1A), .text("x")])
    }

    @Test("ESC sequences with and without intermediates")
    func escapes() {
        #expect(
            parse("\u{1B}7\u{1B}(0\u{1B}#8") == [
                .esc(intermediates: [], final: "7"), .esc(intermediates: [0x28], final: "0"),
                .esc(intermediates: [0x23], final: "8"),
            ])
    }

    @Test("ESC restarts a sequence in progress")
    func escRestarts() {
        #expect(
            parse("\u{1B}[12\u{1B}[3A") == [.csi(marker: nil, params: [3], colons: [], intermediates: [], final: "A")])
    }

    @Test("OSC ends at BEL or at ST")
    func osc() {
        #expect(parse("\u{1B}]0;Death Race\u{07}") == [.osc("0;Death Race", bel: true)])
        #expect(
            parse("\u{1B}]2;dé 999\u{1B}\\x") == [
                .osc("2;dé 999", bel: false), .esc(intermediates: [], final: "\\"), .text("x"),
            ])
    }

    @Test("DCS strings arrive whole with their header")
    func dcs() {
        #expect(
            parse("\u{1B}P$qm\u{1B}\\") == [
                .dcs(marker: nil, params: [], intermediates: [0x24], final: "q", data: "m"),
                .esc(intermediates: [], final: "\\"),
            ])
        #expect(
            parse("\u{1B}P+q544e\u{1B}\\").first
                == .dcs(marker: nil, params: [], intermediates: [0x2B], final: "q", data: "544e"))
    }

    @Test("APC strings are delivered; SOS and PM are swallowed")
    func apc() {
        #expect(parse("\u{1B}_Gf=24;AAAA\u{1B}\\").first == .apc("Gf=24;AAAA"))
        #expect(parse("\u{1B}Xsecret\u{1B}\\ok").last == .text("ok"))
        #expect(parse("\u{1B}^private\u{1B}\\").count == 1)  // just the ST
    }

    @Test("sequences survive being split across reads")
    func splitReads() {
        let events = parse(
            Array("\u{1B}[3".utf8), Array("8;5;19".utf8), Array("6mok ❯".utf8.prefix(5)), Array("❯".utf8.dropFirst(0)))
        #expect(events.first == .csi(marker: nil, params: [38, 5, 196], colons: [], intermediates: [], final: "m"))
    }

    @Test("a character split across reads is decoded once")
    func splitCharacter() {
        let bytes = Array("❯".utf8)
        #expect(parse([0x61] + bytes[0..<1], Array(bytes[1...]) + [0x62]) == [.text("a❯b")])
    }

    @Test("invalid UTF-8 becomes U+FFFD, and a control still executes")
    func invalidUTF8() {
        #expect(parse([0x61, 0xE2, 0x9D, 0x0A, 0x62]) == [.text("a\u{FFFD}"), .execute(0x0A), .text("b")])
        #expect(parse([0xFF]) == [.text("\u{FFFD}")])
    }

    @Test("a byte that cuts a character short and is itself invalid is a second U+FFFD")
    func invalidUTF8Twice() {
        // E0 needs A0...BF next; 80 ends it, then 80 alone is invalid too.
        #expect(parse([0xE0, 0x80, 0x41]) == [.text("\u{FFFD}\u{FFFD}A")])
        // F0 9F then a new lead byte: one U+FFFD, then the new character decodes.
        #expect(parse([0xF0, 0x9F, 0xC3, 0xA9]) == [.text("\u{FFFD}é")])
        // Split across reads, the same.
        #expect(parse([0xE0], [0x80], [0x41]) == [.text("\u{FFFD}\u{FFFD}A")])
    }

    @Test("C1 controls encoded as UTF-8 are dropped")
    func c1Dropped() {
        #expect(parse([0x61, 0xC2, 0x85, 0x62]) == [.text("ab")])
    }

    @Test("parameters beyond 32 are dropped and large values clamp")
    func paramLimits() {
        let many = (1...40).map(String.init).joined(separator: ";")
        if case .csi(_, let params, _, _, _)? = parse("\u{1B}[\(many)m").first {
            #expect(params.count == Params.capacity)
            #expect(params.last == 32)
        } else {
            Issue.record("expected a CSI")
        }
        #expect(
            parse("\u{1B}[99999999A") == [.csi(marker: nil, params: [65535], colons: [], intermediates: [], final: "A")]
        )
    }

    @Test("a sequence with three intermediates is ignored")
    func tooManyIntermediates() {
        #expect(parse("\u{1B}[1 !\"p").isEmpty)
    }

    @Test("DEL is ignored")
    func delIgnored() {
        #expect(parse("a\u{7F}b") == [.text("ab")])
    }

    @Test("the printable scan agrees with a byte-by-byte check", arguments: 0..<64)
    func scanMatchesNaive(seed: Int) {
        var generator = SeededGenerator(seed: UInt64(seed))
        let length = Int(generator.next() % 70)
        // Mostly printable, with an occasional byte from the edges and beyond.
        let edges: [UInt8] = [0x00, 0x1B, 0x1F, 0x20, 0x7E, 0x7F, 0x80, 0xC2, 0xFF]
        let bytes = (0..<length).map { _ -> UInt8 in
            generator.next() % 9 == 0
                ? edges[Int(generator.next() % UInt64(edges.count))] : UInt8(0x20 + generator.next() % 95)
        }
        let naive = bytes.firstIndex { $0 < 0x20 || $0 > 0x7E } ?? bytes.count
        let fast = bytes.withUnsafeBufferPointer { buffer in
            buffer.baseAddress.map { printableASCIIRun($0, buffer.count) } ?? 0
        }
        #expect(fast == naive)
    }
}

struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed &+ 0x9E37_79B9_7F4A_7C15 }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
