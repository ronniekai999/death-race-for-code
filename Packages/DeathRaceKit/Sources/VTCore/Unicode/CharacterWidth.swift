/// How many cells a character occupies, and the properties that decide whether it joins the
/// character before it. Everything comes from one property byte per scalar, looked up in a
/// two-stage table generated from the UCD (`UnicodeTables`): two array loads, no searching.
public enum CharacterWidth {
    /// 0 for characters that combine with the previous one, 2 for wide ones, else 1.
    @inline(__always)
    public static func of(_ scalar: UInt32) -> Int {
        // Latin, Greek, Cyrillic below the combining diacriticals are all width 1.
        if scalar < 0x300 { return scalar >= 0x20 && (scalar < 0x7F || scalar >= 0xA0) ? 1 : 0 }
        return Int(properties(of: scalar) & UnicodeTables.widthMask)
    }

    static let zeroWidthJoiner: UInt32 = 0x200D
    static let variationSelector15: UInt32 = 0xFE0E
    static let variationSelector16: UInt32 = 0xFE0F

    @inline(__always)
    static func isRegionalIndicator(_ scalar: UInt32) -> Bool {
        scalar >= 0x1F1E6 && scalar <= 0x1F1FF
    }

    @inline(__always)
    static func isExtendedPictographic(_ scalar: UInt32) -> Bool {
        scalar >= 0xA9 && properties(of: scalar) & UnicodeTables.pictographic != 0
    }

    @inline(__always)
    static func isEmojiModifier(_ scalar: UInt32) -> Bool {
        scalar >= 0x1F3FB && scalar <= 0x1F3FF
    }

    @inline(__always)
    static func isGraphemeExtend(_ scalar: UInt32) -> Bool {
        scalar >= 0x300 && properties(of: scalar) & UnicodeTables.extend != 0
    }

    /// The property byte of `scalar`: width in the low two bits, then the flags.
    @inline(__always)
    static func properties(of scalar: UInt32) -> UInt8 {
        guard scalar < 0x11_0000 else { return 1 }
        let block = Int(table.blockIndexes[Int(scalar >> 8)])
        return table.blocks[block << 8 | Int(scalar & 0xFF)]
    }

    /// The decoded tables, built once on first use.
    private static let table = Table()

    private struct Table {
        let blockIndexes: [UInt16]
        let blocks: [UInt8]

        init() {
            var values = [UInt8](repeating: 0, count: 128)
            UnicodeTables.alphabet.withUTF8Buffer { symbols in
                for (value, symbol) in symbols.enumerated() { values[Int(symbol)] = UInt8(value) }
            }
            blockIndexes = UnicodeTables.blockIndexes.withUTF8Buffer { symbols in
                stride(from: 0, to: symbols.count, by: 2).map {
                    UInt16(values[Int(symbols[$0])]) << 6 | UInt16(values[Int(symbols[$0 + 1])])
                }
            }
            blocks = UnicodeTables.blocks.withUTF8Buffer { symbols in symbols.map { values[Int($0)] } }
        }
    }
}
