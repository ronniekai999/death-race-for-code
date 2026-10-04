import Testing

@testable import VTCore

@Suite struct CharacterWidthTests {
    @Test(arguments: [
        (UInt32(0x61), 1), (0x0, 0), (0x7F, 0), (0x9B, 0), (0xAD, 1), (0x301, 0), (0x200D, 0), (0xFE0F, 0),
        (0x1160, 0), (0x4E2D, 2), (0xAC00, 2), (0xFF21, 2), (0x1F44D, 2), (0x1F3FD, 2), (0x1F1FA, 2), (0x2764, 1),
        (0x2603, 1), (0x231A, 2), (0xE000, 1), (0x10FFFF, 1), (0x110000, 1),
    ])
    func widths(scalar: UInt32, width: Int) {
        #expect(CharacterWidth.of(scalar) == width)
    }

    @Test func graphemeProperties() {
        #expect(CharacterWidth.isExtendedPictographic(0x2764))
        #expect(CharacterWidth.isExtendedPictographic(0x1F468))
        #expect(!CharacterWidth.isExtendedPictographic(0x4E2D))
        #expect(!CharacterWidth.isExtendedPictographic(0x41))
        #expect(CharacterWidth.isGraphemeExtend(0x301))
        #expect(CharacterWidth.isGraphemeExtend(0xFE0F))
        #expect(!CharacterWidth.isGraphemeExtend(0x4E2D))
        #expect(CharacterWidth.isRegionalIndicator(0x1F1FA))
        #expect(CharacterWidth.isEmojiModifier(0x1F3FD))
        #expect(CharacterWidth.properties(of: 0x1F1FA) & UnicodeTables.regional != 0)
        #expect(CharacterWidth.properties(of: 0x1F3FD) & UnicodeTables.modifier != 0)
    }
}
