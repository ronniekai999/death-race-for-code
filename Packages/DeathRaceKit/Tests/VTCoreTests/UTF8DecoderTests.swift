import Testing

@testable import VTCore

private func decode(_ bytes: [UInt8]) -> [UInt32] {
    var decoder = UTF8Decoder()
    return decoder.decode(bytes)
}

private let fffd: UInt32 = 0xFFFD

@Suite("UTF8Decoder")
struct UTF8DecoderTests {
    @Test("ASCII passes straight through")
    func ascii() {
        #expect(decode(Array("999 ❯".utf8)) == [0x39, 0x39, 0x39, 0x20, 0x276F])
    }

    @Test(
        "every encoding length decodes",
        arguments: [
            ("é", UInt32(0xE9)), ("❯", 0x276F), ("😈", 0x1F608), ("\u{10FFFF}", 0x10FFFF),
        ])
    func lengths(text: String, scalar: UInt32) {
        #expect(decode(Array(text.utf8)) == [scalar])
    }

    @Test("a character split across reads survives")
    func splitAcrossReads() {
        var decoder = UTF8Decoder()
        let bytes = Array("😈".utf8)
        #expect(decoder.decode(bytes[0..<2]) == [])
        #expect(decoder.isMidSequence)
        #expect(decoder.decode(bytes[2...]) == [0x1F608])
    }

    // The examples below are the Unicode Standard's own (Table 3-8 and §3.9).
    @Test("one U+FFFD per maximal subpart")
    func maximalSubparts() {
        // 61 F1 80 80 E1 80 C2 62 80 63 80 BF 64
        let bytes: [UInt8] = [0x61, 0xF1, 0x80, 0x80, 0xE1, 0x80, 0xC2, 0x62, 0x80, 0x63, 0x80, 0xBF, 0x64]
        #expect(decode(bytes) == [0x61, fffd, fffd, fffd, 0x62, fffd, 0x63, fffd, fffd, 0x64])
    }

    @Test("overlong forms are rejected byte by byte")
    func overlong() {
        #expect(decode([0xC0, 0xAF]) == [fffd, fffd])
        #expect(decode([0xE0, 0x80, 0xAF]) == [fffd, fffd, fffd])
    }

    @Test("surrogates and values past U+10FFFF are rejected")
    func outOfRange() {
        #expect(decode([0xED, 0xA0, 0x80]) == [fffd, fffd, fffd])
        #expect(decode([0xF4, 0x90, 0x80, 0x80]) == [fffd, fffd, fffd, fffd])
        #expect(decode([0xF5]) == [fffd])
    }

    @Test("a truncated sequence before ASCII yields one replacement and keeps the ASCII")
    func truncatedBeforeASCII() {
        #expect(decode([0xE2, 0x9D, 0x41]) == [fffd, 0x41])
    }

    @Test("reset reports whether a character was in progress")
    func resetReports() {
        var decoder = UTF8Decoder()
        _ = decoder.feed(0xE2)
        let first = decoder.reset()
        let second = decoder.reset()
        #expect(first)
        #expect(!second)
    }
}
